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

    public func build() async throws -> BuildArtifacts {
        guard plan.target.triple == buildSettings.triple else {
            throw StringError("Build settings target differs from the resolved plan")
        }
        guard plan.target.platform != .macOS,
              plan.allProducts.allSatisfy({
                  if case .library(let name) = $0.resolvedSource { return name == $0.product }
                  return false
              }) else {
            throw StringError("Only iOS library-wrapper compilation is implemented")
        }
        let xtoolDir = URL(fileURLWithPath: "xtool")
        let packageDir = xtoolDir.appendingPathComponent(".xtool-tmp")
        try? FileManager.default.removeItem(at: packageDir)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)

        let packageSwift = packageDir.appendingPathComponent("Package.swift")
        let contents = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "\(plan.app.product)-Builder",
            platforms: [
                .iOS("\(plan.app.deploymentTarget)"),
            ],
            dependencies: [
                .package(name: "RootPackage", path: "../.."),
            ],
            targets: [
                \(
                    plan.allProducts.map {
                        """
                        .executableTarget(
                            name: "\($0.targetName)",
                            dependencies: [
                                .product(name: "\($0.product)", package: "RootPackage"),
                            ],
                            linkerSettings: \($0.linkerSettings)
                        )
                        """
                    }
                    .joined(separator: ",\n")
                )
            ]
        )\n
        """
        try Data(contents.utf8).write(to: packageSwift)

        for product in plan.allProducts {
            let sources: URL = packageDir.appendingPathComponent("Sources/\(product.targetName)", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data().write(to: sources.appendingPathComponent("stub.c", isDirectory: false))
        }

        let buildConfig = try await buildSettings
            .withPackagePath(packageDir.path)
            .swiftPMInvocation(
                forTool: "build",
                arguments: [
                    "--scratch-path", ".build",
                    // resolving can cause SwiftPM to overwrite the root package deps
                    // with just the deps needed for the builder package (which is to
                    // say, any "dev dependencies" of the root package may be removed.)
                    // fortunately we've already resolved the root package by this point
                    // in order to dump the plan, so we can skip resolution here to skirt
                    // the issue.
                    "--disable-automatic-resolution",
                ],
            )
        try await Subprocess.run(
            buildConfig,
            output: .currentStandardOutput,
            error: .currentStandardError,
        )
        .checkSuccess()
        let binPath: String
        switch buildSettings.buildSystem {
        case .swiftPM:
            binPath = "\(buildSettings.triple)/\(buildSettings.configuration.rawValue)"
        case .swiftBuild:
            let platformName = buildSettings.triple.contains("simulator") ? "iphonesimulator" : "iphoneos"
            binPath = "out/Products/\(buildSettings.configuration.swiftBuildValue)-\(platformName)"
        }
        let binDir = URL(
            fileURLWithPath: ".build/\(binPath)",
            isDirectory: true
        )

        return BuildArtifacts(
            directory: binDir,
            executables: Dictionary(uniqueKeysWithValues: plan.allProducts.map {
                ($0.product, binDir.appendingPathComponent($0.targetName))
            })
        )
    }
}

extension Plan.Product {
    fileprivate var linkerSettings: String {
        switch self.type {
        case .application: """
        [
            .unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
            ]),
        ]
        """
        case .xpcService, .helperExecutable: "[]"
        case .appExtension: """
        [
            // Link to Foundation framework which implements the _NSExtensionMain entrypoint
            .linkedFramework("Foundation"),
            .unsafeFlags([
                // Set the entry point to Foundation`_NSExtensionMain
                "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                // Include frameworks that the host app may use
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../Frameworks",
                // ...as well as our own
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
            ]),
        ]
        """
        }
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
