import XCLIUtils
import XPIF
import Foundation
import XUtils
import Dependencies

public struct SwiftPMBuildDescriber {
    let buildSettings: BuildSettings
    let schema: PackSchema
    let idSpecifier: PackSchema.IDSpecifier

    static let supportedPlatforms = ["macosx", "iphoneos", "iphonesimulator"]

    public init(buildSettings: BuildSettings, schema: PackSchema) throws {
        self.buildSettings = buildSettings
        self.schema = schema
        self.idSpecifier = schema.idSpecifier
    }

    func describe() async throws -> BuildDescription {
        try describe(basePIF: await d.swiftPMPIFDumper.dump(buildSettings: buildSettings))
    }

    /// Generated dynamic variants remain in the graph, but are not separate manifest products.
    static func products(in project: XPIF.Project) -> [XPIF.Target] {
        let targets = project.targets.compactMap { base -> XPIF.Target? in
            guard case .target(let target) = base else { return nil }
            return target
        }
        let variants = Set(targets.compactMap(\.dynamicTargetVariantId))
        return targets.filter { $0.id.value.hasPrefix("PACKAGE-PRODUCT:") && !variants.contains($0.id) }
    }

    func describe(basePIF pif: XPIF.Container) throws -> BuildDescription {
        var container = pif
        #if !os(macOS)
        container.workspace.projects = container.workspace.projects.map { $0.withoutRelocatableLinkage() }
        #endif
        let mainProjectIndex = try container.workspace.projects.firstIndex {
            $0.projectDir == container.workspace.path && $0.id != "AGGREGATE"
        }.orThrow(Console.Error("Could not find main target"))
        var project = container.workspace.projects[mainProjectIndex]
        let products = try bundleProducts(in: project)
        let root = URL(filePath: container.workspace.path, directoryHint: .isDirectory)
        // we don't use TemporaryDirectory: we need stable paths to avoid the PIF changing, but
        // TemporaryDirectory includes a random UUID in the path
        // Stable paths also keep Swift Build's incremental state reusable.
        let temporaryDirectory = root.appending(path: "xtool/.xtool-tmp")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let source = temporaryDirectory.appending(path: "empty.c")
        try writeIfChanged(Data(), to: source)

        for product in products {
            if product.packageProduct.productType == .staticArchive {
                var packageProduct = product.packageProduct
                // Let SwiftBuild expand the app or extension product's libraries into the final link. A static
                // archive cannot carry its dynamic dependencies into the app or extension's linker command.
                packageProduct.productType = .packageProduct
                project[target: .init(rawValue: packageProduct.id)] = packageProduct
            }
            let target = try bundleTarget(
                product, extensions: product.isExtension ? [] : Array(products.dropFirst()),
                root: root, source: source, project: &project
            )
            try project.addTarget { _ in target }
        }
        container.workspace.projects[mainProjectIndex] = project
        return BuildDescription(pif: container, buildSettings: buildSettings)
    }

    private func bundleTarget(
        _ product: ProjectProduct,
        extensions: [ProjectProduct],
        root: URL,
        source: URL,
        project: inout XPIF.Project
    ) throws -> XPIF.Target {
        let id = product.targetGUID
        let settings = try bundleSettings(product, root: root)
        let sourceReference = project.mainGroup.addFileReference { _ in
            XPIF.FileReference(id: "\(id):source-ref", path: source.path, pathBase: .absolute)
        }
        var phases: [XPIF.BuildPhase] = [
            .sources(.init(id: "\(id):sources", files: [
                .init(id: "\(id):source", fileRef: sourceReference),
            ])),
            .frameworks(.init(id: "\(id):frameworks", files: [
                .init(id: "\(id):product", ref: .targetProduct(id: product.packageProduct.id)),
            ])),
        ]
        let resources = resourceBuildFiles(product, root: root, project: &project)
        if !resources.isEmpty {
            // Copy verbatim, including directory resources, just as the original packer did.
            phases.append(.copyFiles(.init(
                common: .init(id: "\(id):resources", files: resources),
                destinationSubfolder: .resources
            )))
        }
        if !extensions.isEmpty {
            phases.append(.copyFiles(.init(
                common: .init(id: "\(id):extensions", files: extensions.map { ext in
                    .init(id: "\(id):embed:\(ext.product)", ref: .targetProduct(id: ext.targetGUID),
                          removeHeadersOnCopy: true)
                }),
                destinationSubfolder: .plugins
            )))
        }
        return XPIF.Target(
            id: id,
            productType: product.isExtension ? .appExtension : .application,
            name: product.targetName,
            productName: "\(product.product).\(product.isExtension ? "appex" : "app")",
            approvedByUser: true,
            buildConfigs: ["Debug", "Release"].map { configuration in
                .init(id: "\(id):\(configuration)", name: configuration, settings: settings)
            },
            buildPhases: phases,
            dependencies: [.init(targetId: product.packageProduct.id)]
                + extensions.map { .init(targetId: $0.targetGUID) }
        )
    }

    private func bundleSettings(_ product: ProjectProduct, root: URL) throws -> XPIF.BuildSettings {
        let (plist, plistSettings) = try product.infoPlistConfiguration(at: root)
        var settings = plistSettings
        if !plist.isEmpty {
            let directory = root.appending(path: "xtool/.xtool-tmp/\(product.targetName)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let infoPath = directory.appending(path: "Info.plist")
            try writeIfChanged(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: infoPath)
            settings[.INFOPLIST_FILE] = infoPath.path
        }
        // Swift Build specializes the app or extension for the build request's run destination.
        // Deployment targets are inherited from SwiftPM's project configurations.
        settings[.SDKROOT] = "auto"
        settings[.SDK_VARIANT] = "auto"
        settings[.SUPPORTED_PLATFORMS] = Self.supportedPlatforms
        if let entitlementsPath = product.entitlementsPath {
            settings[single: "CODE_SIGN_ENTITLEMENTS"] = URL(fileURLWithPath: entitlementsPath, relativeTo: root)
                .standardizedFileURL.path
        }
        settings[.SKIP_INSTALL] = product.isExtension ? "YES" : "NO"
        settings[.INSTALL_PATH] = "/"
        settings[.LD_RUNPATH_SEARCH_PATHS, .iOS] = ["$(inherited)", "@executable_path/Frameworks"]
        settings[.LD_RUNPATH_SEARCH_PATHS, .macOS] = ["$(inherited)", "@executable_path/../Frameworks"]
        if product.isExtension {
            settings[.APPLICATION_EXTENSION_API_ONLY] = "YES"
            // SwiftPM selects swiftc as the linker driver, but Swift Build's extension
            // product type passes -fapplication-extension, which requires clang.
            settings[single: "LINKER_DRIVER"] = "clang"
            settings[.LD_RUNPATH_SEARCH_PATHS, .iOS] = [
                "$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks",
            ]
            settings[.LD_RUNPATH_SEARCH_PATHS, .macOS] = [
                "$(inherited)", "@executable_path/../Frameworks", "@executable_path/../../../../Frameworks",
            ]
        }
        return settings
    }

    private func resourceBuildFiles(
        _ product: ProjectProduct, root: URL, project: inout XPIF.Project
    ) -> [XPIF.BuildFile] {
        var visited: Set<String> = []
        let paths = product.resources + (product.iconPath.map { [$0] } ?? [])
        return paths.enumerated().compactMap { index, path in
            let url = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
            guard visited.insert(url.path).inserted else { return nil }
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            let id: XPIF.GUID = "\(product.targetGUID):resource:\(index)"
            let reference = project.mainGroup.addFileReference { _ in
                XPIF.FileReference(id: "\(id):ref", path: url.path, pathBase: .absolute,
                                   fileType: isDirectory.boolValue ? "folder" : nil)
            }
            return .init(id: id, fileRef: reference)
        }
    }

    private func writeIfChanged(_ data: Data, to url: URL) throws {
        guard (try? Data(contentsOf: url)) != data else { return }
        try data.write(to: url)
    }
}

private extension ProjectProduct {
    var targetGUID: XPIF.GUID {
        isExtension ? "xtool:extension:\(product)" : "xtool:main-app"
    }
}

extension XPIF.Project {
    func withoutRelocatableLinkage() -> XPIF.Project {
        var project: XPIF.Project = self
        project.targets = project.targets.map { base in
            guard case var .target(target) = base else { return base }
            if target.productType == .commonStaticArchive {
                // `commonStaticArchive` combines individual `.o` files into one mega `.o` for
                // the entire module, using `<linker> -r`.
                //
                // Unfortunately, lld (which we use on Linux) doesn't yet support `-r` for Darwin
                // targets. So use the `objectLibrary` product type instead, which keeps around
                // loose `.o` files for each source file, instead of trying to merge them.
                target.productType = .objectLibrary
                // FIXME: objlib breaks lipo for fat binaries targetting macOS
            }
            return .target(target)
        }
        return project
    }
}
