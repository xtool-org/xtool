import Dependencies
import Foundation
import Testing
@testable import PackLib
import XUtils

struct ProductBuilderTests {
    private func product(
        _ name: String, source: ProductSource, kind: Plan.ProductType = .application, target: ResolvedTarget
    ) -> Plan.Product {
        Plan.Product(target: target, source: source, type: kind, product: name,
                     bundleID: "test.\(name)", infoPlist: [:], resources: [])
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private actor Recorder {
        var builds: [(BuildSettings, [String])] = []
        var queries: [(BuildSettings, [String])] = []
        let output: URL

        init(output: URL) { self.output = output }

        func build(_ settings: BuildSettings, arguments: [String]) throws {
            builds.append((settings, arguments))
            let index = try #require(arguments.firstIndex(of: "--product"))
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let executable = output.appendingPathComponent(arguments[index + 1])
            try Data("fixture".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        func binaryPath(_ settings: BuildSettings, arguments: [String]) -> String {
            queries.append((settings, arguments))
            return output.path + "\n"
        }

        nonisolated var runner: ProductBuildRunner {
            ProductBuildRunner(build: { try await self.build($0, arguments: $1) },
                               binaryPath: { await self.binaryPath($0, arguments: $1) },
                               sdkLinkerArguments: { _ in [] })
        }
    }

    @Test(arguments: ["arm64-apple-macosx15.0", "arm64-apple-macos15.0", "arm64-apple-macos", "arm64-apple-macosx"])
    func sdkIdentityAndDeploymentAreSeparate(triple: String) async throws {
        let target = try ResolvedTarget.resolve(cliTarget: triple, packageDeploymentTargets: ["macos": "15.0"])
        let settings = try await BuildSettings(configuration: .release, triple: triple)
        let resolved = try settings.withTarget(target)
        #expect(resolved.buildSystem == .swiftPM)
        #expect(resolved.sdkOptions == ["--swift-sdk", "arm64-apple-macosx", "--triple", "arm64-apple-macosx15.0"])
        #expect(resolved.sdkEnvironment["SDKROOT"] != nil)
    }

    @Test func packageMinimumAndUserOptionsSurvive() async throws {
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-ios", packageDeploymentTargets: ["ios": "17.2"])
        let settings = try await BuildSettings(configuration: .debug, triple: target.triple, buildSystem: .swiftPM,
                                               options: ["-Xswiftc", "-DUSER_OPTION", "--jobs", "2"])
        let resolved = try settings.withTarget(target)
        #expect(resolved.sdkOptions == ["--swift-sdk", "arm64-apple-ios", "--triple", "arm64-apple-ios17.2"])
        #expect(resolved.customOptions == settings.customOptions)
        #expect(resolved.configuration == .debug)
    }

    @Test(arguments: [("arm64-apple-ios", "arm64-apple-ios17.2"), ("arm64-apple-ios18.0", "arm64-apple-ios18.0")])
    func swiftBuildKeepsTheRequestedTriple(triple: String, planned: String) async throws {
        // A versioned triple makes SwiftBuild compile every package for that deployment target;
        // dependencies must keep their own minimum, so the plan's version stays out of `--triple`.
        let target = try ResolvedTarget.resolve(cliTarget: triple, packageDeploymentTargets: ["ios": "17.2"])
        let settings = try await BuildSettings(configuration: .release, triple: target.triple, buildSystem: .swiftBuild)
        let resolved = try settings.withTarget(target)
        #expect(target.compilerTriple == planned)
        #expect(resolved.sdkOptions == settings.sdkOptions)
        #expect(Array(resolved.sdkOptions.prefix(2)) == ["--triple", triple])
    }

    @Test(arguments: [BuildConfiguration.debug, .release])
    func directExecutablesUseBackendPaths(configuration: BuildConfiguration) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-ios17.0")
        let plan = try Plan(target: target, app: product("App", source: .executable(product: "ActualExecutable"), target: target))
        let settings = try await BuildSettings(configuration: configuration, triple: target.triple, buildSystem: .swiftPM,
                                               packagePath: root.path, options: ["--jobs", "2"])
        let output = root.appendingPathComponent("backend-selected/\(configuration.rawValue)")
        let recorder = Recorder(output: output)
        let artifacts = try await withDependencies {
            $0.productBuildRunner = recorder.runner
        } operation: {
            try await ProductBuilder(buildSettings: settings, plan: plan).build()
        }
        #expect(artifacts.directory.path == output.path)
        #expect(artifacts.executables["App"] == output.appendingPathComponent("ActualExecutable"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("xtool/.xtool-tmp/Package.swift").path))
        let builds = await recorder.builds
        let queries = await recorder.queries
        #expect(builds.count == 1)
        #expect(builds[0].0.packagePath == root.path)
        #expect(builds[0].0.customOptions == ["--jobs", "2"])
        #expect(builds[0].0.sdkOptions == ["--swift-sdk", "arm64-apple-ios", "--triple", target.compilerTriple])
        #expect(builds[0].1.contains("ActualExecutable"))
        #expect(!builds[0].1.contains("-Xlinker"))
        let toolsetIndex = try #require(builds[0].1.firstIndex(of: "--toolset"))
        let toolsetData = try Data(contentsOf: URL(fileURLWithPath: builds[0].1[toolsetIndex + 1]))
        let toolset = try #require(JSONSerialization.jsonObject(with: toolsetData) as? [String: Any])
        #expect(toolset["schemaVersion"] as? String == "1.0")
        #expect(queries[0].1 == builds[0].1)
        #expect(queries[0].0.configuration == configuration)
    }

    @Test(arguments: ["arm64-apple-ios17.0", "arm64-apple-macosx15.0"])
    func wrappersLinkSelectedLibraryAndExtension(triple: String) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try ResolvedTarget.resolve(cliTarget: triple)
        let plan = try Plan(target: target, app: product("App", source: .library(product: "AppLibrary"), target: target),
                            extensions: [product("Preview", source: .library(product: "PreviewLibrary"),
                                                 kind: .appExtension, target: target)])
        let settings = try await BuildSettings(configuration: .release, triple: triple, buildSystem: .swiftPM,
                                               packagePath: root.path)
        let recorder = Recorder(output: root.appendingPathComponent("target-output"))
        let artifacts = try await withDependencies {
            $0.productBuildRunner = recorder.runner
        } operation: {
            try await ProductBuilder(buildSettings: settings, plan: plan).build()
        }
        let manifest = try String(contentsOf: root.appendingPathComponent("xtool/.xtool-tmp/Package.swift"), encoding: .utf8)
        #expect(manifest.contains(".product(name: \"AppLibrary\""))
        #expect(manifest.contains(".product(name: \"PreviewLibrary\""))
        #expect(manifest.contains("_NSExtensionMain"))
        #expect(manifest.contains("Foundation"))
        #expect(manifest.contains(target.platform == .macOS ? ".macOS(\"15.0\")" : ".iOS(\"17.0\")"))
        #expect(manifest.contains(target.platform == .macOS
                                 ? "@executable_path/../../../../Frameworks" : "@executable_path/../../Frameworks"))
        #expect(artifacts.executables["App"]?.lastPathComponent == "App-App")
        #expect(artifacts.executables["Preview"]?.lastPathComponent == "Preview-Extension")
        #expect(await recorder.builds.allSatisfy { !$0.1.contains("-Xlinker") })
        // Both products share the wrapper package, so its output directory is queried once.
        #expect(await recorder.queries.count == 1)
    }

    @Test func macOSResourceAccessorsBuildOnceWithStableFlags() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        var app = product("App", source: .library(product: "AppLibrary"), target: target)
        app.resources = [.bundle(package: "Package", target: "Resources")]
        var helper = product("Helper", source: .library(product: "AppLibrary"), kind: .xpcService, target: target)
        helper.resources = app.resources
        let plan = try Plan(target: target, app: app, nestedProducts: [helper])
        let settings = try await BuildSettings(configuration: .release, triple: target.triple, buildSystem: .swiftPM,
                                               packagePath: root.path)
        let output = root.appendingPathComponent("target-output")
        let accessor = output.appendingPathComponent("Resources.build/DerivedSources/resource_bundle_accessor.swift")
        let generated = """
        import Foundation
        extension Foundation.Bundle {
            static let module: Bundle = {
                let mainPath = Bundle.main.bundleURL.appendingPathComponent("Package_Resources.bundle").path
                return Bundle(path: mainPath)!
            }()
        }
        """
        @Sendable func generate() throws {
            // SwiftPM generates the accessor while planning, before compiling.
            try FileManager.default.createDirectory(at: accessor.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(generated.utf8).writeIfChanged(to: accessor)
        }
        func build(planGenerates: Bool = true) async throws -> (plans: [[String]], builds: [[String]]) {
            let recorder = Recorder(output: output)
            let plans = Recorder(output: output)
            _ = try await withDependencies {
                $0.productBuildRunner = ProductBuildRunner(
                    build: { settings, arguments in
                        try generate()
                        try await recorder.build(settings, arguments: arguments)
                    },
                    binaryPath: { await recorder.binaryPath($0, arguments: $1) },
                    sdkLinkerArguments: { _ in [] },
                    plan: { settings, arguments in
                        if planGenerates { try generate() }
                        try await plans.build(settings, arguments: arguments)
                    })
            } operation: {
                try await ProductBuilder(buildSettings: settings, plan: plan).build()
            }
            return (await plans.builds.map(\.1), await recorder.builds.map(\.1))
        }

        // A clean build plans first, so the overlay adapts the accessors before anything compiles:
        // one pass per product, with the flags it plans with.
        let clean = try await build()
        #expect(clean.plans == clean.builds)
        #expect(clean.builds.count == 2)
        #expect(clean.builds.allSatisfy { $0.contains("-vfsoverlay") })
        let cleanDate = try FileManager.default.attributesOfItem(atPath: accessor.path)[.modificationDate] as? Date

        // A no-op rebuild skips planning and runs one pass per product with exactly the previous flags.
        let rebuilt = try await build()
        #expect(rebuilt.plans.isEmpty)
        #expect(rebuilt.builds == clean.builds)
        let rebuiltDate = try FileManager.default.attributesOfItem(atPath: accessor.path)[.modificationDate] as? Date
        #expect(cleanDate == rebuiltDate)

        // If planning does not produce an accessor, the build adapts it afterwards and compiles it
        // again with identical flags, so other modules do not recompile. This holds even though
        // the adapted copy from the earlier build is unchanged: the build itself did not use it.
        try FileManager.default.removeItem(at: output)
        let fallback = try await build(planGenerates: false)
        #expect(fallback.builds.count == 4)
        #expect(fallback.builds[0] == fallback.builds[2] && fallback.builds[1] == fallback.builds[3])
    }

    @Test func unsupportedCombinationsReject() async throws {
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        let debug = try await BuildSettings(configuration: .debug, triple: target.triple, buildSystem: .swiftPM)
        #expect(throws: (any Error).self) { try debug.validateProductBuild(for: target, hostIsMacOS: false) }
        try debug.validateProductBuild(for: target, hostIsMacOS: true)
        let release = try await BuildSettings(configuration: .release, triple: target.triple, buildSystem: .swiftPM)
        try release.validateProductBuild(for: target, hostIsMacOS: false)
        await #expect(throws: (any Error).self) {
            try await BuildSettings(configuration: .release, triple: target.triple, buildSystem: .swiftBuild)
        }
    }

    @Test(arguments: [ProductSource.prebuilt(path: "/external/helper"), .executable(product: "../escape")])
    func invalidSourcesRejectBeforeWriting(source: ProductSource) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx")
        let plan = try Plan(target: target, app: product("App", source: source, target: target))
        let settings = try await BuildSettings(configuration: .release, triple: target.triple, buildSystem: .swiftPM,
                                               packagePath: root.path)
        await #expect(throws: (any Error).self) {
            try await withDependencies {
                $0.productBuildRunner = ProductBuildRunner(build: { _, _ in Issue.record("Unexpected build") },
                                                           binaryPath: { _, _ in Issue.record("Unexpected query"); return "" })
            } operation: {
                try await ProductBuilder(buildSettings: settings, plan: plan).build()
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test(arguments: ["--triple=arm64-apple-ios", "--arch", "--configuration=debug", "--product", "--show-bin-path"])
    func conflictingOptionsReject(option: String) async throws {
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx")
        let settings = try await BuildSettings(configuration: .release, triple: target.triple, buildSystem: .swiftPM,
                                               options: [option])
        #expect(throws: (any Error).self) { try settings.validateProductBuild(for: target, hostIsMacOS: false) }
    }

    @Test func missingBackendExecutableRejects() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-ios")
        let plan = try Plan(target: target, app: product("App", source: .executable(product: "Missing"), target: target))
        let settings = try await BuildSettings(configuration: .release, triple: target.triple, buildSystem: .swiftPM,
                                               packagePath: root.path)
        await #expect(throws: (any Error).self) {
            try await withDependencies {
                $0.productBuildRunner = ProductBuildRunner(build: { _, _ in }, binaryPath: { _, _ in root.path })
            } operation: {
                try await ProductBuilder(buildSettings: settings, plan: plan).build()
            }
        }
    }
    #if os(macOS)
    @Test(arguments: [BuildConfiguration.debug, .release])
    func nativeExecutableAndLibraryFixture(configuration: BuildConfiguration) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "BuilderFixture",
            platforms: [.macOS(.v10_15)],
            products: [.executable(name: "DirectExecutable", targets: ["Direct"]),
                       .executable(name: "ServiceExecutable", targets: ["ServiceMain"]),
                       .library(name: "HelperLibrary", targets: ["Helper", "Gate"])],
            targets: [.executableTarget(name: "Direct", resources: [.copy("message.txt")]),
                      .executableTarget(name: "ServiceMain"), .target(name: "Helper"), .target(name: "Gate")]
        )
        """
        try Data(manifest.utf8).write(to: root.appendingPathComponent("Package.swift"))
        let direct = root.appendingPathComponent("Sources/Direct")
        let helper = root.appendingPathComponent("Sources/Helper")
        try FileManager.default.createDirectory(at: direct, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("include"), withIntermediateDirectories: true)
        try Data("import AppKit\nprint(NSApplication.self)".utf8).write(to: direct.appendingPathComponent("main.swift"))
        let service = root.appendingPathComponent("Sources/ServiceMain")
        try FileManager.default.createDirectory(at: service, withIntermediateDirectories: true)
        try Data("print(1)".utf8).write(to: service.appendingPathComponent("main.swift"))
        // Modules compile for their package's own minimum (macOS 10.15), not the plan's 15.0:
        // like swift-perception's Bindable, this backport's extension is unavailable from macOS 14.
        let gate = root.appendingPathComponent("Sources/Gate")
        try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)
        try Data("""
        @available(macOS, introduced: 10.15, obsoleted: 14)
        public struct Backport {}
        extension Backport: Equatable {}
        """.utf8).write(to: gate.appendingPathComponent("Gate.swift"))
        try Data("resource fixture".utf8).write(to: direct.appendingPathComponent("message.txt"))
        try Data("#include <vector>\nint main() { std::vector<int> values(3, 1); return values.at(1); }".utf8)
            .write(to: helper.appendingPathComponent("Entry.cpp"))
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macos15.0")
        // Direct and wrapped products alternate, so each build follows another package's build in the shared scratch.
        let plan = try Plan(target: target,
                            app: product("App", source: .executable(product: "DirectExecutable"), target: target),
                            extensions: [product("Preview", source: .library(product: "HelperLibrary"),
                                                 kind: .appExtension, target: target)],
                            nestedProducts: [product("Helper", source: .library(product: "HelperLibrary"),
                                                     kind: .helperExecutable, target: target),
                                             product("Service", source: .executable(product: "ServiceExecutable"),
                                                     kind: .xpcService, target: target)])
        let settings = try await BuildSettings(configuration: configuration, triple: target.triple, buildSystem: .swiftPM,
                                               packagePath: root.path)
        let artifacts = try await withDependencies {
            $0.productBuildRunner = .liveValue
        } operation: {
            try await ProductBuilder(buildSettings: settings, plan: plan).build()
        }
        #expect(artifacts.executables.count == 4)
        #expect(artifacts.directory.lastPathComponent == configuration.rawValue)
        #expect(FileManager.default.isExecutableFile(atPath: try #require(artifacts.executables["App"]).path))
        #expect(FileManager.default.isExecutableFile(atPath: try #require(artifacts.executables["Helper"]).path))
        let expectedSDK = try #require(try await settings.withTarget(target).macOSLinkerArguments().last)
        for product in plan.allProducts {
            let executable = try #require(artifacts.executables[product.product])
            let slice = try #require(MachOBinary.inspect(Array(Data(contentsOf: executable))).first)
            #expect(slice.platform == 1)
            #expect(slice.minimumOS == MachOBinary.packedVersion("15.0"))
            #expect(slice.sdk == MachOBinary.packedVersion(expectedSDK))
            #expect(Set(product.runtimeSearchPaths).isSubset(of: Set(slice.rpaths)))
            // An ARM64 linker signature is not Developer ID or release signing.
            #expect(slice.hasCodeSignature)
        }
        let resource = artifacts.directory.appendingPathComponent("BuilderFixture_Direct.bundle/message.txt")
        #expect(try String(contentsOf: resource, encoding: .utf8) == "resource fixture")
    }
    #endif

}
