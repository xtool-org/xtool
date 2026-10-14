import Foundation
import XUtils

/// Stages completed artifacts without compiling, provisioning, signing, or publishing.
public struct BundleAssembler: Sendable {
    public let plan: Plan
    public let sourceDirectory: URL

    public init(plan: Plan, sourceDirectory: URL) {
        self.plan = plan
        self.sourceDirectory = sourceDirectory
    }

    /// The destination must be empty. All inputs and destinations are checked before copying.
    public func assemble(artifacts: BuildArtifacts, at outputURL: URL) throws {
        let assembly = try operations(artifacts: artifacts)
        try validate(assembly, outputURL: outputURL)
        let manager = FileManager.default
        try manager.createDirectory(at: outputURL, withIntermediateDirectories: true)
        for path in assembly.directories.sorted() {
            try manager.createDirectory(at: outputURL.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for operation in assembly.operations {
            try Task.checkCancellation()
            let destination = outputURL.appendingPathComponent(operation.path)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch operation.payload {
            case .copy(let source): try manager.copyItem(at: source, to: destination)
            case .data(let data): try data.write(to: destination, options: .withoutOverwriting)
            case .symlink(let target): try manager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
            }
        }
    }

    private enum Payload: Hashable {
        case copy(URL)
        case data(Data)
        case symlink(String)
    }

    private struct Operation: Hashable {
        var path: String
        var payload: Payload
    }

    private struct Assembly {
        var directories: Set<String> = []
        var operations: [Operation] = []
        var dependencyProducts: [Operation: Set<String>] = [:]
    }

    private func operations(artifacts: BuildArtifacts) throws -> Assembly {
        var assembly = Assembly()
        for product in plan.allProducts {
            try validateName(product.product)
            let layout = product.layout
            for path in [layout.bundlePath, layout.contentsPath, layout.resourcesPath, layout.frameworksPath,
                         (layout.executablePath as NSString).deletingLastPathComponent] where !path.isEmpty {
                assembly.directories.insert(path)
            }
            // A helper's bundlePath is its executable, not a directory.
            if product.type == .helperExecutable { assembly.directories.remove(layout.bundlePath) }
            guard let executable = artifacts.executables[product.product],
                  FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw StringError("Missing built executable for product '\(product.product)'")
            }
            assembly.operations.append(.init(path: layout.executablePath, payload: .copy(executable)))
            if let path = layout.infoPlistPath {
                assembly.operations.append(.init(path: path, payload: .data(try plist(for: product))))
            }
            for resource in product.resources {
                try append(resource, product: product, artifacts: artifacts, to: &assembly)
            }
            if let icon = product.iconPath {
                let source = sourceURL(icon)
                let path = joined(layout.resourcesPath, source.lastPathComponent)
                assembly.operations.append(.init(path: path, payload: .copy(source)))
            }
        }
        return assembly
    }

    private func append(
        _ resource: Plan.Resource, product: Plan.Product, artifacts: BuildArtifacts, to assembly: inout Assembly
    ) throws {
        let layout = product.layout
        switch resource {
        case .bundle(let package, let target):
            try validateName(package)
            try validateName(target)
            let name = "\(package)_\(target).bundle"
            let path = joined(layout.resourcesPath, name)
            appendDependency(.init(path: path, payload: .copy(artifacts.directory.appendingPathComponent(name))),
                             product: product, to: &assembly)
            if product.platform == .macOS && product.type == .helperExecutable {
                // Bare helpers retain SwiftPM's executable-directory lookup. Real bundles use
                // the resourceURL accessor compiled by ProductBuilder; root aliases cannot be signed.
                appendDependency(.init(path: joined(layout.contentsPath, name),
                                       payload: .symlink("../Resources/\(name)")),
                                 product: product, to: &assembly)
            }
        case .binaryTarget(let name):
            try validateName(name)
            let source = artifacts.directory.appendingPathComponent("\(name).framework")
            let binary = source.appendingPathComponent(name)
            if artifacts.staticBinaryTargets.contains(name) {
                let looseArchive = ProductBuilder.staticArchive(forBinaryTarget: name, in: artifacts.directory,
                                                                target: plan.target)
                guard FileManager.default.fileExists(atPath: binary.path)
                    || FileManager.default.fileExists(atPath: looseArchive.path) else {
                    throw StringError("Missing validated static binary target '\(name)' in \(artifacts.directory.path)")
                }
                // ProductBuilder inspected the archive and confirmed that SwiftPM
                // linked it into the executable. Static code is not embedded.
                return
            }
            // iOS SwiftPM omits some linked static binary targets from the output tree.
            // Retain that legacy omission; macOS declared inputs must be present and classified.
            if product.platform != .macOS && !FileManager.default.fileExists(atPath: binary.path) { return }
            try validateInput(source)
            guard FileManager.default.fileExists(atPath: binary.path) else {
                throw StringError("Framework '\(name)' has no readable binary at \(binary.path)")
            }
            if try !isArchive(binary) {
                appendDependency(.init(path: joined(layout.frameworksPath, source.lastPathComponent), payload: .copy(source)),
                                 product: product, to: &assembly)
            }
        case .library(let name):
            try validateName(name)
            let source = artifacts.directory.appendingPathComponent("lib\(name).dylib")
            try validateInput(source)
            if try !isArchive(source) {
                appendDependency(.init(path: joined(layout.frameworksPath, source.lastPathComponent), payload: .copy(source)),
                                 product: product, to: &assembly)
            }
        case .root(let path):
            let source = sourceURL(path)
            // Legacy resources go where Bundle.main looks: the bundle root on iOS, Contents/Resources on
            // macOS. The macOS bundle root is outside the code signature's resource seal.
            let destination = ResourceDestination(path: source.lastPathComponent)
            assembly.operations.append(.init(path: try layout.path(for: destination), payload: .copy(source)))
        case .copy(let copy):
            assembly.operations.append(.init(path: try layout.path(for: copy.destination), payload: .copy(sourceURL(copy.source))))
        }
    }

    private func appendDependency(_ operation: Operation, product: Plan.Product, to assembly: inout Assembly) {
        // Helpers share resources with the app and dependencies with other helpers. Coalesce exact
        // generated operations across products, but reject repeated declarations within one product.
        let inserted = assembly.dependencyProducts[operation, default: []].insert(product.product).inserted
        if inserted && assembly.dependencyProducts[operation]?.count != 1 { return }
        assembly.operations.append(operation)
    }

    private func plist(for product: Plan.Product) throws -> Data {
        var info = product.infoPlist
        if product.type == .application && product.platform != .macOS {
            info["UIRequiredDeviceCapabilities"] = ["arm64"]
            info["LSRequiresIPhoneOS"] = true
            info["CFBundleSupportedPlatforms"] = [product.platform.supportedPlatform]
        }
        if let icon = product.iconPath, info["CFBundleIconFile"] == nil {
            info["CFBundleIconFile"] = URL(fileURLWithPath: icon).deletingPathExtension().lastPathComponent
        }
        return try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    }

    private func validate(_ assembly: Assembly, outputURL: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: outputURL.path) {
            guard try manager.contentsOfDirectory(atPath: outputURL.path).isEmpty else {
                throw StringError("Bundle staging destination must be empty: \(outputURL.path)")
            }
        }
        let directories = assembly.directories.map(canonicalPath)
        var destinations: [String] = []
        for operation in assembly.operations {
            try ResourceDestination.validateRelativePath(operation.path)
            let path = canonicalPath(operation.path)
            guard !directories.contains(where: { $0 == path || $0.hasPrefix(path + "/") }),
                  !destinations.contains(where: { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }) else {
                throw StringError("Bundle destination collision at '\(operation.path)'")
            }
            destinations.append(path)
            if case .copy(let source) = operation.payload {
                try validateInput(source)
                let sourcePath = source.resolvingSymlinksInPath().path
                let outputPath = outputURL.resolvingSymlinksInPath().path
                guard outputPath != sourcePath, !outputPath.hasPrefix(sourcePath + "/") else {
                    throw StringError("Bundle staging destination is inside input '\(source.path)'")
                }
            }
        }
    }

    private func validateInput(_ source: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else {
            throw StringError("Missing bundle input: \(source.path)")
        }
        // Top-level links to a build-tree payload would break after relocation; require an owned payload.
        if try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw StringError("Bundle input must be a payload rather than a top-level symbolic link: \(source.path)")
        }
        try validateEntry(source, root: source)
        if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            guard let enumerator = manager.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
                throw StringError("Cannot enumerate bundle input: \(source.path)")
            }
            while let entry = enumerator.nextObject() as? URL { try validateEntry(entry, root: source) }
        }
    }

    private func validateEntry(_ entry: URL, root: URL) throws {
        let rawAssets = ["xcassets", "iconset", "storyboard", "xib"]
        if rawAssets.contains(entry.pathExtension.lowercased()) {
            throw StringError("Raw asset '\(entry.path)' requires Apple asset compilation; supply prepared "
                              + "Assets.car, .icns, or compiled resources using resource-copies instead")
        }
        if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
            let resolved = entry.resolvingSymlinksInPath().standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            guard !link.hasPrefix("/"), resolved.hasPrefix(rootPath + "/"),
                  FileManager.default.fileExists(atPath: resolved) else {
                throw StringError("Broken or escaping symbolic link in bundle input: \(entry.path) -> \(link)")
            }
        }
    }

    private func isArchive(_ source: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 8)
        return bytes == Data("!<arch>\n".utf8) || bytes == Data("!<thin>\n".utf8)
    }

    private func sourceURL(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return sourceDirectory.appendingPathComponent(path).standardizedFileURL
    }

    private func validateName(_ name: String) throws {
        try ResourceDestination.validateRelativePath(name)
        guard !name.contains("/") else { throw StringError("Bundle input names must not contain path separators: '\(name)'") }
    }

    private func canonicalPath(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    private func joined(_ base: String, _ path: String) -> String {
        [base, path].filter { !$0.isEmpty }.joined(separator: "/")
    }
}
