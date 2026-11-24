import XCLIUtils
import XUtils
import Foundation
import Crypto
import Dependencies
import XcodePIFConversion
import XcodeProjects
import XPIF

/// Resolves all Xcode package references as one SwiftPM graph.
struct XcodePackagePIFBuilder {
    let builder: XcodePIFBuilder
    /// Directory under which xtool stores its package resolution scratch space.
    let rootDirectory: URL

    func build() async throws -> [XPIF.Project] {
        guard !builder.packageReferences.isEmpty else { return [] }
        let references = builder.packageReferences
        let manifest = try Self.manifest(references: references)
        let rootPaths = Self.rootPaths(references)
        // SwiftPM's checkout paths appear in PIF. Keep the workspace stable across builds.
        let key = SHA256.hash(data: Data(builder.packageWorkspaceURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = rootDirectory.appending(path: "xtool/.xtool-tmp/packages/\(key)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appending(path: "Package.swift")
        if (try? String(contentsOf: manifestURL, encoding: .utf8)) != manifest {
            try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        }
        let resolved = builder.packageWorkspaceURL.appending(path: "xcshareddata/swiftpm/Package.resolved")
        if let data = try? Data(contentsOf: resolved) {
            try data.write(to: directory.appending(path: "Package.resolved"), options: .atomic)
        }
        @Dependency(\.swiftPMPIFDumper) var dumper
        let pif = try await dumper.dump(packagePath: directory)
        let defaults = try await XcodePackageSDKDefaults.load()
        let allTargets = Dictionary(uniqueKeysWithValues: pif.workspace.projects.flatMap(\.targets).map { ($0.id, $0) })
        var pending = allTargets.values.compactMap { base -> XPIF.GUID? in
            guard case .target(let target) = base, target.id.value.hasPrefix("PACKAGE-PRODUCT:"),
                  ![.unitTest, .uiTest, .swiftpmTestRunner].contains(target.productType) else { return nil }
            return target.id
        }
        var reachable: Set<XPIF.GUID> = []
        while let id = pending.popLast() {
            guard reachable.insert(id).inserted, let target = allTargets[id] else { continue }
            pending += target.common.dependencies.map(\.targetId)
            if case .target(let target) = target, let dynamic = target.dynamicTargetVariantId { pending.append(dynamic) }
        }
        return pif.workspace.projects.filter {
            $0.id != "AGGREGATE" && URL(filePath: $0.projectDir).resolvingSymlinksInPath().path
                != directory.resolvingSymlinksInPath().path
        }.map { project in
            var project = project
            // SwiftPM CLI includes test products; Xcode includes only the product dependency graph.
            project.targets.removeAll { !reachable.contains($0.id) }
            // Xcode emits a resource bundle before its first consuming module. The
            // SwiftPM CLI emits it afterwards; project target references keep their order.
            var emitted: Set<XPIF.GUID> = []
            project.targetSerializationOrder = (project.targetSerializationOrder ?? project.targets.map(\.id))
                .filter { reachable.contains($0) }.flatMap { id -> [XPIF.GUID] in
                    let resources = id.value.hasPrefix("PACKAGE-TARGET:") ? allTargets[id]?.common.dependencies.map(\.targetId)
                        .filter { $0.value.hasPrefix("PACKAGE-RESOURCE:") } ?? [] : []
                    return (resources + [id]).filter { emitted.insert($0).inserted }
                }
            Self.configureProject(&project, defaults: defaults,
                                  isRoot: rootPaths.contains(URL(filePath: project.projectDir).resolvingSymlinksInPath().path))
            for index in project.targets.indices {
                for config in project.targets[index].common.buildConfigs.indices {
                    var configuration = project.targets[index].common.buildConfigs[config]
                    // These are standalone CLI documentation and non-Darwin linker settings,
                    // not settings supplied by Xcode's package PIF integration.
                    for key in configuration.settings.values.keys where
                        ["DOCC_EXTRACT_PROJECT_HEADERS_DOCUMENTATION", "SYMBOL_GRAPH_EXTRACTOR_OUTPUT_DIR",
                         "TAPI_EXTRACT_API_OUTPUT_DIR"].contains(key)
                        || key.hasPrefix("SWIFT_DISABLE_COMPILATION_FOR_STATIC_LINKING_WHEN_ANY_TARGET_IS_PROMOTED_TO_DYNAMIC[") {
                        configuration.settings.values.removeValue(forKey: key)
                    }
                    if configuration.impartedBuildProperties.settings.values["LD_RUNPATH_SEARCH_PATHS"]
                        == .array(["$(RPATH_ORIGIN)", "$(inherited)"]) {
                        configuration.impartedBuildProperties.settings.values.removeValue(forKey: "LD_RUNPATH_SEARCH_PATHS")
                    }
                    project.targets[index].common.buildConfigs[config] = configuration
                }
            }
            return project
        }
    }

    private static func rootPaths(_ references: [XcodePIFBuilder.PackageReference]) -> Set<String> {
        Set(references.filter(\.isRoot).compactMap { reference -> String? in
            guard case .local(let package) = reference.package.location else { return nil }
            return URL(fileURLWithPath: package.path, relativeTo: reference.sourceRoot)
                .standardizedFileURL.resolvingSymlinksInPath().path
        })
    }

    private static func configureProject(_ project: inout XPIF.Project, defaults: XcodePackageSDKDefaults, isRoot: Bool) {
        for index in project.buildConfigs.indices {
            defaults.apply(to: &project.buildConfigs[index].settings)
            if isRoot { project.buildConfigs[index].settings.values.removeValue(forKey: "BUILD_SERVER_PROTOCOL_TARGET_TAGS") }
        }
    }

    static func manifest(references: [XcodePIFBuilder.PackageReference]) throws -> String {
        var dependencies: [String: String] = [:]
        for reference in references {
            let identity: String
            var arguments: String
            switch reference.package.location {
            case .local(let local):
                let sourceRoot = URL(filePath: reference.sourceRoot.path, directoryHint: .isDirectory)
                let url = URL(fileURLWithPath: local.path, relativeTo: sourceRoot)
                    .standardizedFileURL.resolvingSymlinksInPath()
                identity = url.lastPathComponent.lowercased()
                arguments = "path: \(String(reflecting: url.path))"
            case .remote(let remote):
                let component = (remote.repositoryURL as NSString).lastPathComponent
                identity = (component.hasSuffix(".git") ? String(component.dropLast(4)) : component).lowercased()
                guard let constraint = remote.versionConstraint else {
                    throw Console.Error("Swift package '\(remote.repositoryURL)' needs a version, branch, or revision requirement.")
                }
                arguments = "url: \(String(reflecting: remote.repositoryURL)), " + requirement(constraint)
            }
            if !reference.package.traits.isEmpty {
                arguments += ", traits: [\(reference.package.traits.sorted().map { String(reflecting: $0) }.joined(separator: ", "))]"
            }
            let dependency = ".package(\(arguments))"
            if let existing = dependencies[identity], existing != dependency {
                throw Console.Error("Conflicting references for Swift package '\(identity)'.")
            }
            dependencies[identity] = dependency
        }
        let declarations = dependencies.sorted { $0.key < $1.key }.map { "        \($0.value)," }.joined(separator: "\n")
        return """
        // swift-tools-version: 6.1
        import PackageDescription

        let package = Package(
            name: "XtoolDependencies",
            dependencies: [
        \(declarations)
            ]
        )

        """
    }

    private static func requirement(_ constraint: XCSchema.SwiftPackageVersionConstraint) -> String {
        switch constraint {
        case .revision(let value): "revision: \(String(reflecting: value))"
        case .branch(let value): "branch: \(String(reflecting: value))"
        case .version(let value): "exact: \(String(reflecting: value))"
        case .versionRange(let min, let max): "\(String(reflecting: min))..<\(String(reflecting: max))"
        case .upToNextMinorVersion(let value): ".upToNextMinor(from: \(String(reflecting: value)))"
        case .upToNextMajorVersion(let value): "from: \(String(reflecting: value))"
        }
    }
}
