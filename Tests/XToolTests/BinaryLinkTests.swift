import Dependencies
import Foundation
import Testing
@testable import PackLib

struct BinaryLinkTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func product(_ name: String, kind: Plan.ProductType, target: ResolvedTarget) -> Plan.Product {
        Plan.Product(target: target, source: .prebuilt(path: name), type: kind, product: name,
                     bundleID: "test.\(name)", infoPlist: [:], resources: [])
    }

    private func binary(cpu: UInt32 = 0x0100000c, platform: UInt32 = 1,
                        minimum: UInt32 = 0x0f0000, type: UInt32 = 2) -> Data {
        let words: [UInt32] = [0xfeedfacf, cpu, 0, type, 1, 24, 0, 0, 0x32, 24, platform, minimum, 0x1a0200, 0]
        return Data(words.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } })
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test(arguments: [Plan.ProductType.application, .appExtension, .xpcService, .helperExecutable])
    func rpathsResolveAgainstFrozenLayout(kind: Plan.ProductType) throws {
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        let product = product("Item", kind: kind, target: target)
        let root = URL(fileURLWithPath: "/Relocated/App.app")
        let executable = root.appendingPathComponent(product.layout.executablePath).deletingLastPathComponent()
        let paths = product.runtimeSearchPaths.map {
            executable.appendingPathComponent(String($0.dropFirst("@executable_path/".count))).standardizedFileURL.path
        }
        #expect(paths.first == root.appendingPathComponent("Contents/Frameworks").path)
        #expect(paths.contains(root.appendingPathComponent(product.layout.frameworksPath).path))
        #expect(Set(paths).count == paths.count)
    }

    @Test func helperOnlyDynamicDependencyResolvesFromEmittedRpath() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        try write(binary(), to: root.appendingPathComponent("App"))
        try write(binary(), to: root.appendingPathComponent("Helper"))
        let installName = "@rpath/libHelperRuntime.dylib"
        var library = binary(type: 6)
        let string = Array(installName.utf8) + [0]
        let size = (24 + string.count + 7) / 8 * 8
        let command: [UInt32] = [0xd, UInt32(size), 24, 0, 0, 0]
        library[16] = 2
        library[20] = UInt8(24 + size)
        library += Data(command.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } })
        library += Data(string + Array(repeating: 0, count: size - 24 - string.count))
        try library.write(to: root.appendingPathComponent("libHelperRuntime.dylib"))
        let helper = Plan.Product(target: target, source: .executable(product: "Helper"),
                                  type: .helperExecutable, product: "Helper", bundleID: "test.Helper",
                                  infoPlist: [:], resources: [.library(name: "HelperRuntime")])
        let plan = try Plan(target: target, app: product("App", kind: .application, target: target),
                            nestedProducts: [helper])
        let settings = try await BuildSettings(configuration: .release, triple: target.triple, packagePath: root.path)
        let artifacts = try await withDependencies {
            $0.productBuildRunner = .init(build: { _, _ in }, binaryPath: { _, _ in root.path },
                                          sdkLinkerArguments: { _ in [] })
        } operation: {
            try await ProductBuilder(buildSettings: settings, plan: plan).build()
        }
        let toolsetURL = root.appendingPathComponent("xtool/.xtool-tmp/toolsets/\(helper.targetName).json")
        let toolset = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: toolsetURL)) as? [String: Any])
        let linker = try #require(toolset["linker"] as? [String: Any])
        let arguments = try #require(linker["extraCLIOptions"] as? [String])
        let rpaths = arguments.indices.filter { arguments[$0] == "-rpath" }.map { arguments[$0 + 1] }
        let compiler = try #require(toolset["swiftCompiler"] as? [String: Any])
        #expect(compiler["extraCLIOptions"] as? [String] == ["-target", target.compilerTriple])
        #expect(rpaths == ["@executable_path/../Frameworks", "@executable_path/Frameworks"])

        let output = root.appendingPathComponent("Relocated/App.app")
        try BundleAssembler(plan: plan, sourceDirectory: root).assemble(artifacts: artifacts, at: output)
        let dependency = output.appendingPathComponent("Contents/Helpers/Frameworks/libHelperRuntime.dylib")
        #expect(try Data(contentsOf: dependency) == library)
        let outerDependency = output.appendingPathComponent("Contents/Frameworks/libHelperRuntime.dylib")
        #expect(!FileManager.default.fileExists(atPath: outerDependency.path))
        let executableDirectory = output.appendingPathComponent(helper.layout.executablePath).deletingLastPathComponent()
        let relativeLibrary = String(installName.dropFirst("@rpath/".count))
        let candidates = rpaths.map {
            executableDirectory.appendingPathComponent(String($0.dropFirst("@executable_path/".count)))
                .appendingPathComponent(relativeLibrary).standardizedFileURL
        }
        #expect(candidates.filter { FileManager.default.fileExists(atPath: $0.path) } == [dependency])
    }

    @Test func prebuiltOnlyBuildPreservesPathsWithoutCompiler() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        try write(binary(), to: root.appendingPathComponent("App"))
        try write(binary(), to: root.appendingPathComponent("Helper"))
        let plan = try Plan(target: target, app: product("App", kind: .application, target: target),
                            nestedProducts: [product("Helper", kind: .helperExecutable, target: target)])
        let settings = try await BuildSettings(configuration: .release, triple: target.triple, packagePath: root.path)
        let artifacts = try await withDependencies {
            $0.productBuildRunner = .init(build: { _, _ in Issue.record("Unexpected build") },
                                          binaryPath: { _, _ in Issue.record("Unexpected output query"); return "" },
                                          sdkLinkerArguments: { _ in Issue.record("Unexpected SDK query"); return [] })
        } operation: {
            try await ProductBuilder(buildSettings: settings, plan: plan).build()
        }
        #expect(artifacts.executables["App"] == root.appendingPathComponent("App"))
        #expect(artifacts.executables["Helper"] == root.appendingPathComponent("Helper"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("xtool").path))
    }

    @Test func incompatiblePrebuiltDiagnostics() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        let url = root.appendingPathComponent("Input")
        let cases: [(Data, String)] = [
            (binary(cpu: 0x01000007), "Wrong architecture"),
            (binary(platform: 2), "platform"),
            (binary(minimum: 0x100000), "minimum OS"),
            (binary(type: 6), "file type"),
            (Data("#!/bin/sh\n".utf8), "Mach-O"),
            (Data([0xcf, 0xfa, 0xed, 0xfe]), "Truncated"),
        ]
        for (data, diagnostic) in cases {
            try write(data, to: url)
            do {
                try MachOBinary.validate(url, target: target, executable: true)
                Issue.record("Accepted invalid binary: \(diagnostic)")
            } catch {
                #expect(String(describing: error).contains(diagnostic))
                #expect(String(describing: error).contains(url.path))
            }
        }
    }

    @Test func universalBinarySelectsMatchingSliceAndRejectsTruncation() throws {
        let slices = [binary(cpu: 0x01000007), binary()]
        var data = Data()
        let header: [UInt32] = [0xcafebabe, 2, 0x01000007, 0, 48, 56, 0, 0x0100000c, 0, 104, 56, 0]
        for word in header { data += Data((0..<4).map { UInt8(truncatingIfNeeded: word >> ((3 - $0) * 8)) }) }
        data += slices[0] + slices[1]
        #expect(try MachOBinary.inspect(Array(data)).count == 2)
        #expect(throws: (any Error).self) { try MachOBinary.inspect(Array(data.dropLast())) }
    }

    @Test func universalStaticArchiveIsStatic() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        func archive(_ object: Data) -> Data {
            let size = String(object.count).padding(toLength: 10, withPad: " ", startingAt: 0)
            return Data("!<arch>\nfile.o/         0           0     0     100644  \(size)`\n".utf8) + object
        }
        let slices = [archive(binary(cpu: 0x01000007, type: 1)), archive(binary(type: 1))]
        let header: [UInt32] = [0xcafebabe, 2, 0x01000007, 0, 48, UInt32(slices[0].count), 0,
                                0x0100000c, 0, UInt32(48 + slices[0].count), UInt32(slices[1].count), 0]
        var data = Data()
        for word in header { data += Data((0..<4).map { UInt8(truncatingIfNeeded: word >> ((3 - $0) * 8)) }) }
        let url = root.appendingPathComponent("Fat")
        try (data + slices[0] + slices[1]).write(to: url)
        for architecture in ["arm64", "x86_64"] {
            let target = try ResolvedTarget.resolve(cliTarget: "\(architecture)-apple-macosx15.0")
            #expect(try MachOBinary.validate(url, target: target, executable: false))
            #expect(throws: (any Error).self) { try MachOBinary.validate(url, target: target, executable: true) }
        }
    }

    @Test func staticBinaryTargetsRequireRealArchive() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        try write(binary(), to: root.appendingPathComponent("App"))
        var app = product("App", kind: .application, target: target)
        app.resources = [.binaryTarget(name: "Static")]
        let plan = try Plan(target: target, app: app)
        let settings = try await BuildSettings(configuration: .release, triple: target.triple, packagePath: root.path)
        await #expect(throws: (any Error).self) { try await ProductBuilder(buildSettings: settings, plan: plan).build() }
        let object = binary(type: 1)
        let size = String(object.count).padding(toLength: 10, withPad: " ", startingAt: 0)
        let header = "file.o/         0           0     0     100644  \(size)`\n"
        let archive = Data("!<arch>\n\(header)".utf8) + object
        try archive.write(to: root.appendingPathComponent("libStatic.a"))
        let artifacts = try await ProductBuilder(buildSettings: settings, plan: plan).build()
        #expect(artifacts.staticBinaryTargets == ["Static"])
        try Data("!<arch>\n".utf8).write(to: root.appendingPathComponent("libStatic.a"))
        await #expect(throws: (any Error).self) { try await ProductBuilder(buildSettings: settings, plan: plan).build() }
    }

    @Test func staticBinaryTargetArchiveUsesXCFrameworkLibraryPath() async throws {
        let scratch = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("arm64-apple-macosx/release")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let xcframework = scratch.appendingPathComponent("artifacts/package/Static/Static.xcframework")
        try FileManager.default.createDirectory(at: xcframework, withIntermediateDirectories: true)
        let libraries: [[String: Any]] = [
            ["LibraryPath": "libstatic-ios.a", "SupportedPlatform": "ios", "SupportedArchitectures": ["arm64"]],
            ["LibraryPath": "libstatic-fat.a", "SupportedPlatform": "macos", "SupportedArchitectures": ["arm64", "x86_64"]],
        ]
        try PropertyListSerialization.data(fromPropertyList: ["AvailableLibraries": libraries], format: .xml, options: 0)
            .write(to: xcframework.appendingPathComponent("Info.plist"))
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        try write(binary(), to: root.appendingPathComponent("App"))
        var app = product("App", kind: .application, target: target)
        app.resources = [.binaryTarget(name: "Static")]
        let plan = try Plan(target: target, app: app)
        let object = binary(type: 1)
        let size = String(object.count).padding(toLength: 10, withPad: " ", startingAt: 0)
        let header = "file.o/         0           0     0     100644  \(size)`\n"
        try (Data("!<arch>\n\(header)".utf8) + object).write(to: root.appendingPathComponent("libstatic-fat.a"))
        let settings = try await BuildSettings(configuration: .release, triple: target.triple, packagePath: root.path)
        let artifacts = try await ProductBuilder(buildSettings: settings, plan: plan).build()
        #expect(artifacts.staticBinaryTargets == ["Static"])
        let output = scratch.appendingPathComponent("App.app")
        try BundleAssembler(plan: plan, sourceDirectory: root).assemble(artifacts: artifacts, at: output)
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("Contents/Frameworks/Static.framework").path))
    }

    @Test func staticBinaryTargetArchiveUsesLocalXCFrameworkLibraryPath() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // SwiftPM leaves local XCFrameworks in place; only the slice's library reaches the bin directory.
        let xcframework = root.appendingPathComponent("Vendor/Static.xcframework")
        try FileManager.default.createDirectory(at: xcframework, withIntermediateDirectories: true)
        let libraries: [[String: Any]] = [
            ["LibraryPath": "libvendor.a", "SupportedPlatform": "macos", "SupportedArchitectures": ["arm64"]],
        ]
        try PropertyListSerialization.data(fromPropertyList: ["AvailableLibraries": libraries], format: .xml, options: 0)
            .write(to: xcframework.appendingPathComponent("Info.plist"))
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        try write(binary(), to: root.appendingPathComponent("App"))
        var app = product("App", kind: .application, target: target)
        app.resources = [.binaryTarget(name: "Static", xcframework: xcframework.path)]
        let plan = try Plan(target: target, app: app)
        let object = binary(type: 1)
        let size = String(object.count).padding(toLength: 10, withPad: " ", startingAt: 0)
        let header = "file.o/         0           0     0     100644  \(size)`\n"
        try (Data("!<arch>\n\(header)".utf8) + object).write(to: root.appendingPathComponent("libvendor.a"))
        let settings = try await BuildSettings(configuration: .release, triple: target.triple, packagePath: root.path)
        let artifacts = try await ProductBuilder(buildSettings: settings, plan: plan).build()
        #expect(artifacts.staticBinaryTargets == ["Static"])
        try BundleAssembler(plan: plan, sourceDirectory: root)
            .assemble(artifacts: artifacts, at: root.appendingPathComponent("App.app"))
    }

    @Test func dynamicInstallNameMustResolveInsideEmbeddedFramework() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let framework = root.appendingPathComponent("Runtime.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let url = framework.appendingPathComponent("Runtime")
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        for name in ["@rpath/Runtime.framework/Runtime", "/tmp/Runtime", "@rpath/Other.framework/Runtime", "@rpath/../Runtime"] {
            var data = binary(type: 6)
            let string = Array(name.utf8) + [0]
            let size = (24 + string.count + 7) / 8 * 8
            let command: [UInt32] = [0xd, UInt32(size), 24, 0, 0, 0]
            data[16] = 2
            data[20] = UInt8(24 + size)
            data += Data(command.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } })
            data += Data(string + Array(repeating: 0, count: size - 24 - string.count))
            try data.write(to: url)
            if name == "@rpath/Runtime.framework/Runtime" {
                #expect(try !MachOBinary.validate(url, target: target, executable: false))
            } else {
                #expect(throws: (any Error).self) { try MachOBinary.validate(url, target: target, executable: false) }
            }
        }
    }

    @Test func sdkVersionUsesSDKMetadataAndEffectiveDeployment() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("darwin.artifactbundle")
        let sdk = bundle.appendingPathComponent("SDK")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try Data(#"{"targetTriples":{"arm64-apple-macosx":{"sdkRootPath":"SDK"}}}"#.utf8)
            .write(to: bundle.appendingPathComponent("swift-sdk.json"))
        try Data(#"{"Version":"26.2"}"#.utf8).write(to: sdk.appendingPathComponent("SDKSettings.json"))
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx", packageDeploymentTargets: ["macos": "16.0"])
        let settings = try await BuildSettings(configuration: .release, triple: target.triple,
                                               options: ["--swift-sdks-path", root.path]).withTarget(target)
        #expect(try await settings.macOSLinkerArguments() == ["-Xlinker", "-platform_version", "-Xlinker", "macos",
                                                             "-Xlinker", "16.0", "-Xlinker", "26.2"])
    }
}
