import Foundation
import Dependencies
import XUtils
import Subprocess

/// Compilation owns the generated wrapper package and build tree only.
/// Bundle staging and publication belong exclusively to Packer/BundleAssembler.
public struct ProductBuilder: Sendable {
    public let buildSettings: BuildSettings
    public let plan: Plan

    public init(buildSettings: BuildSettings, plan: Plan) {
        self.buildSettings = buildSettings
        self.plan = plan
    }

    @Dependency(\.productBuildRunner) private var runner

    public func build() async throws -> BuildArtifacts {
        #if os(macOS)
        let hostIsMacOS = true
        #else
        let hostIsMacOS = false
        #endif
        try buildSettings.validateProductBuild(for: plan.target, hostIsMacOS: hostIsMacOS)
        try validateProducts()
        let settings = try buildSettings.withTarget(plan.target)
        let root = URL(fileURLWithPath: settings.packagePath, isDirectory: true).standardizedFileURL
        let wrapper = root.appendingPathComponent("xtool/.xtool-tmp", isDirectory: true)
        let libraries = plan.allProducts.filter {
            if case .library = $0.resolvedSource { return true }
            return false
        }
        if !libraries.isEmpty { try createWrapper(at: wrapper, root: root, products: libraries) }

        // Share one scratch tree so resources and dependency libraries remain
        // beside all products, including mixed direct and wrapped products.
        let scratchOptions = settings.customOptions.contains {
            $0 == "--scratch-path" || $0.hasPrefix("--scratch-path=")
        } ? [] : ["--scratch-path", root.appendingPathComponent(".build").path]
        var directory: URL?
        var executables: [String: URL] = [:]
        for product in plan.allProducts {
            let package: URL
            let name: String
            let options: [String]
            switch product.resolvedSource {
            case .library:
                package = wrapper
                name = product.targetName
                // Planning already resolved root dependencies; avoid dropping
                // its development-only dependencies from Package.resolved.
                options = ["--disable-automatic-resolution"]
            case .executable(let sourceName):
                package = root
                name = sourceName
                options = try directProductOptions(product, in: wrapper)
            case .prebuilt:
                // validateProducts rejects these before any side effects.
                throw StringError("Prebuilt product compatibility validation is not implemented")
            }
            let productSettings = settings.withPackagePath(package.path)
            let arguments = scratchOptions + ["--product", name] + options
            try await runner.build(productSettings, arguments)
            let path = try await runner.binaryPath(productSettings, arguments)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !path.contains("\n"), path.hasPrefix("/") else {
                throw StringError("Build backend returned an invalid binary output path: '\(path)'")
            }
            let binDir = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            if let directory, directory != binDir {
                throw StringError("Build backend produced products in different resource directories")
            }
            directory = binDir
            let executable = binDir.appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw StringError("Build backend did not produce executable '\(name)' at \(executable.path)")
            }
            executables[product.product] = executable
        }
        guard let directory else { throw StringError("Build plan has no products") }
        return BuildArtifacts(directory: directory, executables: executables)
    }

    private func directProductOptions(_ product: Plan.Product, in directory: URL) throws -> [String] {
        // SwiftPM forwards CLI -Xlinker options to host macro executables too.
        // SDK toolset options belong only to the target toolchain instead.
        let toolsets = directory.appendingPathComponent("toolsets", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsets, withIntermediateDirectories: true)
        let path = toolsets.appendingPathComponent("\(product.targetName).json")
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": "1.0",
            "swiftCompiler": ["extraCLIOptions": product.linkerArguments],
        ], options: [.sortedKeys])
        try data.write(to: path)
        return ["--toolset", path.path]
    }

    private func validateProducts() throws {
        let names = plan.allProducts.map { product -> String in
            switch product.resolvedSource {
            case .library: product.targetName
            case .executable(let name): name
            case .prebuilt: ""
            }
        }
        guard Set(names).count == names.count else {
            throw StringError("Product build output names collide")
        }
        for product in plan.allProducts {
            try product.resolvedSource.validate()
            try ResourceDestination.validateRelativePath(product.product)
            guard !product.product.contains("/") else {
                throw StringError("Product names must not contain path separators")
            }
            switch product.resolvedSource {
            case .prebuilt:
                throw StringError("Prebuilt product compatibility validation is not implemented; use a SwiftPM product")
            case .executable where buildSettings.buildSystem != .swiftPM:
                throw StringError("Direct executable products currently require the SwiftPM backend")
            case .library(let name), .executable(let name):
                try ResourceDestination.validateRelativePath(name)
                guard !name.contains("/") else {
                    throw StringError("SwiftPM product names must not contain path separators")
                }
            }
        }
    }

    private func createWrapper(at directory: URL, root: URL, products: [Plan.Product]) throws {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let targets = products.map { product in
            let sourceName: String
            if case .library(let name) = product.resolvedSource { sourceName = name } else { sourceName = product.product }
            return """
            .executableTarget(
                name: \(product.targetName.swiftLiteral),
                dependencies: [.product(name: \(sourceName.swiftLiteral), package: "RootPackage")],
                linkerSettings: \(product.linkerSettings)
            )
            """
        }.joined(separator: ",\n")
        let platform = plan.target.platform == .macOS ? "macOS" : "iOS"
        let contents = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: \((plan.app.product + "-Builder").swiftLiteral),
            platforms: [.\(platform)(\(plan.target.deploymentTarget.swiftLiteral))],
            dependencies: [.package(name: "RootPackage", path: \(root.path.swiftLiteral))],
            targets: [
                \(targets)
            ]
        )

        """
        try Data(contents.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        for product in products {
            let sources = directory.appendingPathComponent("Sources/\(product.targetName)", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data().write(to: sources.appendingPathComponent("stub.c"))
        }
    }
}

extension String {
    /// Encode untrusted package/product names as a literal, never manifest code.
    fileprivate var swiftLiteral: String { String(reflecting: self) }
}

extension Plan.Product {
    var linkerArguments: [String] {
        var arguments: [String] = []
        if type == .appExtension {
            arguments += ["-Xlinker", "-framework", "-Xlinker", "Foundation",
                          "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]
        }
        // Paths follow the executable's actual position in the selected layout.
        let own = platform == .macOS ? "@executable_path/../Frameworks" : "@executable_path/Frameworks"
        let outer: String? = switch type {
        case .application: nil
        case .appExtension, .xpcService:
            platform == .macOS ? "@executable_path/../../../../Frameworks" : "@executable_path/../../Frameworks"
        case .helperExecutable: "@executable_path/../Frameworks"
        }
        if let outer { arguments += ["-Xlinker", "-rpath", "-Xlinker", outer] }
        if outer != own { arguments += ["-Xlinker", "-rpath", "-Xlinker", own] }
        return arguments
    }

    fileprivate var linkerSettings: String {
        "[.unsafeFlags([\(linkerArguments.map(\.swiftLiteral).joined(separator: ", "))])]"
    }
}

/// The build backend owns output discovery. Injection lets focused tests assert
/// target/host separation without starting a compiler or provisioning a device.
struct ProductBuildRunner: Sendable {
    var build: @Sendable (BuildSettings, [String]) async throws -> Void
    var binaryPath: @Sendable (BuildSettings, [String]) async throws -> String
}

extension ProductBuildRunner: DependencyKey {
    static let liveValue = Self(
        build: { settings, arguments in
            let invocation = try await settings.swiftPMInvocation(forTool: "build", arguments: arguments)
            try await Subprocess.run(invocation, output: .currentStandardOutput, error: .currentStandardError).checkSuccess()
        },
        binaryPath: { settings, arguments in
            let invocation = try await settings.swiftPMInvocation(forTool: "build", arguments: arguments + ["--show-bin-path"])
            let result = try await Subprocess.run(invocation, output: .string(limit: .max), error: .currentStandardError)
                .checkSuccess()
            return result.standardOutput
        }
    )
}

extension DependencyValues {
    var productBuildRunner: ProductBuildRunner {
        get { self[ProductBuildRunner.self] }
        set { self[ProductBuildRunner.self] = newValue }
    }
}

/// Build outputs are inputs to assembly; the assembler must not invoke SwiftPM.
public struct BuildArtifacts: Sendable {
    public var directory: URL
    public var executables: [String: URL]

    public init(directory: URL, executables: [String: URL]) {
        self.directory = directory
        self.executables = executables
    }
}

public struct ProductBuilderClient: Sendable {
    public var build: @Sendable (BuildSettings, Plan) async throws -> BuildArtifacts

    public init(build: @escaping @Sendable (BuildSettings, Plan) async throws -> BuildArtifacts) {
        self.build = build
    }
}

extension ProductBuilderClient: DependencyKey {
    public static let liveValue = Self { settings, plan in
        try await ProductBuilder(buildSettings: settings, plan: plan).build()
    }
}

extension DependencyValues {
    public var productBuilder: ProductBuilderClient {
        get { self[ProductBuilderClient.self] }
        set { self[ProductBuilderClient.self] = newValue }
    }
}
