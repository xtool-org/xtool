import ArgumentParser
import Dependencies
import Foundation
import Testing
import XKit
import XUtils
@testable import PackLib
@testable import XToolSupport

struct DevCommandTests {
    private struct ForbiddenAuthStorage: KeyValueStorage {
        func data(forKey key: String) throws -> Data? {
            Issue.record("Unexpected authentication read: \(key)")
            throw StringError("Unexpected authentication")
        }

        func setData(_ data: Data?, forKey key: String) throws {
            Issue.record("Unexpected authentication write: \(key)")
            throw StringError("Unexpected authentication")
        }
    }

    private actor Recorder {
        var events: [String] = []
        func record(_ event: String) { events.append(event) }
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func schema(target: String? = nil, entitlements: String? = nil) throws -> PackSchema {
        try PackSchema(validating: .init(
            version: .v2, orgID: "test", product: "App", target: target,
            source: .executable(product: "Executable"), entitlementsPath: entitlements
        ))
    }

    private func client(schema: PackSchema, root: URL) -> DevCommandClient {
        var client = DevCommandClient.testValue
        client.currentDirectory = { root }
        client.loadSchema = { _ in schema }
        client.ensureSDK = { Issue.record("Unexpected SDK setup"); throw StringError("Unexpected SDK setup") }
        client.legacyPack = { _, _, _ in Issue.record("Unexpected legacy packing"); throw StringError("Unexpected legacy packing") }
        client.deferredPack = { _, _ in Issue.record("Unexpected deferred packing"); throw StringError("Unexpected deferred packing") }
        return client
    }

    @Test func buildParserKeepsIOSDefaults() throws {
        let command = try DevBuildCommand.parse([])
        #expect(command.triple == nil)
        #expect(command.packOptions.configuration == .debug)
        #expect(!command.sign)
        #expect(!command.ipa)
        #expect(!command.deferSigning)
        let request = try DevBuildRequest(schema: .default, directory: URL(fileURLWithPath: "/project"))
        #expect(request.triple == "arm64-apple-ios")
        #expect(request.platform == .iOS)
        try request.validate(route: .build(sign: false, ipa: false, deferSigning: false))
        try request.validate(route: .build(sign: true, ipa: true, deferSigning: false))
        try request.validate(route: .run)
        try request.validate(route: .xcode)
    }

    @Test func schemaTargetAndCLIOverrideSelectRoute() throws {
        let directory = URL(fileURLWithPath: "/project")
        let macSchema = try schema(target: "arm64-apple-macosx15.0")
        let configured = try DevBuildRequest(schema: macSchema, directory: directory)
        #expect(configured.triple == "arm64-apple-macosx15.0")
        #expect(configured.platform == .macOS)
        let overridden = try DevBuildRequest(schema: macSchema, cliTriple: "arm64-apple-ios17.0", directory: directory)
        #expect(overridden.triple == "arm64-apple-ios17.0")
        #expect(overridden.platform == .iOS)
        let macOverride = try DevBuildRequest(schema: .default, cliTriple: "x86_64-apple-macosx15.0", directory: directory)
        #expect(macOverride.platform == .macOS)
        try macOverride.validate(route: .build(sign: false, ipa: false, deferSigning: true))
    }

    @Test func runAcceptsTripleAndXcodeStillRejectsIt() throws {
        #expect(try DevRunCommand.parse(["--triple", "arm64-apple-macosx"]).triple == "arm64-apple-macosx")
        #expect(try DevRunCommand.parse(["--", "--cofiguration", "x"]).appArguments == ["--cofiguration", "x"])
        for typo in [["--cofiguration", "release"], ["biuld"], ["--app", "App.app", "--cofiguration", "release"]] {
            #expect(throws: (any Error).self) { try DevRunCommand.parse(typo) }
        }
        #expect(throws: (any Error).self) {
            try DevXcodeCommand.parse(["--triple", "arm64-apple-macosx"])
        }
    }

    @Test(arguments: [[], ["--sign"], ["--ipa"], ["--sign", "--defer-signing"], ["--ipa", "--defer-signing"]])
    func macOSInvalidBuildRoutesFailBeforeEffects(arguments: [String]) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = try DevBuildCommand.parse(arguments)
        let effects = client(schema: try schema(target: "arm64-apple-macosx"), root: directory)
        await #expect(throws: (any Error).self) {
            try await withDependencies {
                $0.devCommandClient = effects
                $0.keyValueStorage = ForbiddenAuthStorage()
            } operation: {
                try await command.run()
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func macOSRunAndXcodeRejectBeforeEffects() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let effects = client(schema: try schema(target: "arm64-apple-macosx"), root: directory)
        await #expect(throws: (any Error).self) {
            try await withDependencies {
                $0.devCommandClient = effects
                $0.keyValueStorage = ForbiddenAuthStorage()
            } operation: {
                try await DevRunCommand.parse([]).run()
            }
        }
        #if os(macOS)
        await #expect(throws: (any Error).self) {
            try await withDependencies {
                $0.devCommandClient = effects
                $0.keyValueStorage = ForbiddenAuthStorage()
            } operation: {
                try await DevRunCommand.parse(["--simulator"]).run()
            }
        }
        #endif
        await #expect(throws: (any Error).self) {
            try await withDependencies {
                $0.devCommandClient = effects
                $0.keyValueStorage = ForbiddenAuthStorage()
            } operation: {
                try await DevXcodeCommand.parse([]).run()
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test(arguments: ["arm64-unknown-linux", "arm64-apple-macosx-invalid"])
    func invalidCLITripleRejectsBeforeEffects(triple: String) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let effects = client(schema: .default, root: directory)
        await #expect(throws: (any Error).self) {
            try await withDependencies {
                $0.devCommandClient = effects
                $0.keyValueStorage = ForbiddenAuthStorage()
            } operation: {
                try await DevBuildCommand.parse(["--triple", triple, "--sign"]).run()
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func macOSCLIOverrideRejectsSigningBeforeAuthentication() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let effects = client(schema: .default, root: directory)
        await #expect(throws: (any Error).self) {
            try await withDependencies {
                $0.devCommandClient = effects
                $0.keyValueStorage = ForbiddenAuthStorage()
            } operation: {
                try await DevBuildCommand.parse(["--triple", "arm64-apple-macosx", "--sign"]).run()
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func deferredSigningRejectsIOSBeforeEffects() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let effects = client(schema: .default, root: directory)
        await #expect(throws: (any Error).self) {
            try await withDependencies {
                $0.devCommandClient = effects
                $0.keyValueStorage = ForbiddenAuthStorage()
            } operation: {
                try await DevBuildCommand.parse(["--defer-signing"]).run()
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private func packageInspection(root: URL) throws -> PackageInspectionClient {
        let dependencies = try JSONSerialization.data(withJSONObject: [
            "identity": "root", "path": root.path, "dependencies": [],
        ])
        let description = try JSONSerialization.data(withJSONObject: [
            "name": "Fixture",
            "platforms": [["name": "macos", "version": "15.0"]],
            "products": [["name": "Executable", "targets": ["Main"], "type": ["executable": NSNull()]]],
            "targets": [["name": "Main", "type": "executable", "module_type": "SwiftTarget", "resources": []]],
        ])
        let manifest = try JSONSerialization.data(withJSONObject: [
            "targets": [["name": "Main", "type": "executable", "dependencies": []]], "dependencies": [],
        ])
        return PackageInspectionClient(
            dependencies: { _ in dependencies }, describe: { _ in description }, manifest: { _ in manifest }
        )
    }

    @Test func deferredBuildUsesSchemaAndPreservesSigningInputsWithoutAuth() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("fixture".utf8).write(to: directory.appendingPathComponent("Package.swift"))
        let entitlementData = try PropertyListSerialization.data(
            fromPropertyList: ["com.apple.security.app-sandbox": true], format: .xml, options: 0
        )
        try entitlementData.write(to: directory.appendingPathComponent("App.entitlements"))
        let recorder = Recorder()
        let configured = try schema(target: "arm64-apple-macosx", entitlements: "App.entitlements")
        var effects = client(schema: configured, root: directory)
        effects.ensureSDK = { await recorder.record("sdk") }
        effects.loadSchema = { _ in await recorder.record("schema"); return configured }
        effects.deferredPack = { settings, plan in
            #expect(settings.triple == "arm64-apple-macosx")
            #expect(settings.configuration == .release)
            #expect(settings.packagePath == directory.path)
            #expect(settings.buildSystem == .swiftPM)
            #expect(plan.target.platform == .macOS)
            #expect(plan.target.deploymentTarget == "15.0")
            #expect(plan.app.resolvedSource == .executable(product: "Executable"))
            await recorder.record("deferred-pack")
            let bundle = directory.appendingPathComponent("App.app", isDirectory: true)
            try MacArtifactTests.fixture(at: bundle)
            return bundle
        }
        let inspection = try packageInspection(root: directory)
        try await withDependencies {
            $0.devCommandClient = effects
            $0.packageInspection = inspection
            $0.keyValueStorage = ForbiddenAuthStorage()
        } operation: {
            try await DevBuildCommand.parse(["--defer-signing", "--configuration", "release"]).run()
        }
        #expect(await recorder.events == ["schema", "sdk", "deferred-pack"])
        let manifestURL = directory.appendingPathComponent("App.signing.json")
        let handoff = try JSONDecoder().decode(DeferredSigningManifest.self, from: Data(contentsOf: manifestURL))
        #expect(handoff.status == .deferred)
        #expect(handoff.products[0].bundlePath == "")
        #expect(handoff.products[0].executablePath == "Contents/MacOS/App")
        let relative = try #require(handoff.products[0].entitlementsPath)
        let copied = manifestURL.deletingLastPathComponent().appendingPathComponent(relative)
        #expect(try Data(contentsOf: copied) == entitlementData)
        let supportsBSP = try await SwiftVersion.current.supportsSwiftBuild
        let editorConfigPath = supportsBSP ? LSPConfig.bsp.0 : LSPConfig.legacyLSP.0
        let alternateConfigPath = supportsBSP ? LSPConfig.legacyLSP.0 : LSPConfig.bsp.0
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(alternateConfigPath).path))
        let editorConfigURL = directory.appendingPathComponent(editorConfigPath)
        let editorConfig = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: editorConfigURL)) as? [String: Any])
        if supportsBSP {
            #expect(editorConfig["argv"] as? [String] == [
                "/usr/bin/env", "xtool", "dev", "build-server", "--triple", "arm64-apple-macosx15.0",
            ])
        } else {
            #expect(editorConfig["swiftPM"] as? [String: String] == [
                "swiftSDK": "arm64-apple-macosx", "triple": "arm64-apple-macosx15.0",
            ])
        }
    }

    private func product(_ name: String, kind: Plan.ProductType, target: ResolvedTarget, entitlements: String?) -> Plan.Product {
        Plan.Product(target: target, type: kind, product: name, bundleID: "test.\(name)",
                     infoPlist: [:], resources: [], entitlementsPath: entitlements)
    }

    @Test func handoffKeepsNestedAssociationsAndMovesWithArtifact() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let output = directory.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let entitlementData = try PropertyListSerialization.data(fromPropertyList: ["test.flag": true], format: .binary, options: 0)
        try entitlementData.write(to: source.appendingPathComponent("shared.plist"))
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        let plan = try Plan(
            target: target, app: product("App", kind: .application, target: target, entitlements: "shared.plist"),
            extensions: [product("Preview", kind: .appExtension, target: target, entitlements: "shared.plist")],
            nestedProducts: [product("Service", kind: .xpcService, target: target, entitlements: "shared.plist"),
                             product("Helper", kind: .helperExecutable, target: target, entitlements: nil)]
        )
        let manifestURL = try DeferredSigningHandoff.write(
            plan: plan, bundle: output.appendingPathComponent("App.app"), sourceDirectory: source
        )
        let moved = directory.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: output, to: moved)
        try FileManager.default.removeItem(at: source)
        let manifest = try JSONDecoder().decode(
            DeferredSigningManifest.self, from: Data(contentsOf: moved.appendingPathComponent(manifestURL.lastPathComponent))
        )
        #expect(manifest.products.map(\.bundleID) == ["test.App", "test.Preview", "test.Service", "test.Helper"])
        #expect(manifest.products.map(\.bundlePath) == ["", "Contents/PlugIns/Preview.appex", "Contents/XPCServices/Service.xpc",
                                                     "Contents/Helpers/Helper"])
        #expect(manifest.products[3].entitlementsPath == nil)
        for product in manifest.products.prefix(3) {
            let path = try #require(product.entitlementsPath)
            #expect(!path.hasPrefix("/"))
            #expect(try Data(contentsOf: moved.appendingPathComponent(path)) == entitlementData)
        }
    }

    @Test func replacingHandoffPreservesPreviousEntitlementGeneration() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("entitlements.plist")
        let first = try PropertyListSerialization.data(fromPropertyList: ["test.flag": true], format: .xml, options: 0)
        try first.write(to: source)
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        let app = product("App", kind: .application, target: target, entitlements: "entitlements.plist")
        let plan = try Plan(target: target, app: app)
        let bundle = directory.appendingPathComponent("App.app")
        let url = try DeferredSigningHandoff.write(plan: plan, bundle: bundle, sourceDirectory: directory)
        let previous = try JSONDecoder().decode(DeferredSigningManifest.self, from: Data(contentsOf: url))
        let previousPath = try #require(previous.products.first?.entitlementsPath)
        let second = try PropertyListSerialization.data(fromPropertyList: ["test.flag": false], format: .xml, options: 0)
        try second.write(to: source)
        _ = try DeferredSigningHandoff.write(plan: plan, bundle: bundle, sourceDirectory: directory)
        let current = try JSONDecoder().decode(DeferredSigningManifest.self, from: Data(contentsOf: url))
        let currentPath = try #require(current.products.first?.entitlementsPath)
        #expect(currentPath != previousPath)
        #expect(try Data(contentsOf: directory.appendingPathComponent(previousPath)) == first)
        #expect(try Data(contentsOf: directory.appendingPathComponent(currentPath)) == second)
    }

    @Test func malformedEntitlementsRejectWithoutWritingHandoff() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a plist".utf8).write(to: directory.appendingPathComponent("bad.plist"))
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        let plan = try Plan(target: target, app: product("App", kind: .application, target: target, entitlements: "bad.plist"))
        #expect(throws: (any Error).self) {
            try DeferredSigningHandoff.write(plan: plan, bundle: directory.appendingPathComponent("App.app"),
                                             sourceDirectory: directory)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["bad.plist"])
    }

    @Test(arguments: [nil, "arm64-apple-ios17.0"])
    func iosBuildForwardsEffectiveTripleWithoutAuthentication(override: String?) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configured = try schema(target: "arm64-apple-ios16.0")
        let recorder = Recorder()
        var effects = client(schema: configured, root: directory)
        effects.legacyPack = { triple, configuration, xcode in
            #expect(triple == (override ?? "arm64-apple-ios16.0"))
            #expect(configuration == .debug)
            #expect(!xcode)
            await recorder.record("ios-pack")
            return directory.appendingPathComponent("App.app")
        }
        let arguments = override.map { ["--triple", $0] } ?? []
        try await withDependencies {
            $0.devCommandClient = effects
            $0.keyValueStorage = ForbiddenAuthStorage()
        } operation: {
            try await DevBuildCommand.parse(arguments).run()
        }
        #expect(await recorder.events == ["ios-pack"])
    }

    @Test func iosIPAPackagingStillUsesCompressor() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = Recorder()
        let app = directory.appendingPathComponent("App.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("app executable".utf8).write(to: app.appendingPathComponent("App"))
        var effects = client(schema: .default, root: directory)
        effects.legacyPack = { triple, _, xcode in
            #expect(triple == "arm64-apple-ios")
            #expect(!xcode)
            return app
        }
        let compressor = ZIPCompressor(
            compress: { payload, _ in
                #expect(payload.lastPathComponent == "Payload")
                #expect(FileManager.default.fileExists(atPath: payload.appendingPathComponent("App.app/App").path))
                await recorder.record("ipa")
                let compressed = directory.appendingPathComponent("compressed.zip")
                try Data("compressed app".utf8).write(to: compressed)
                return compressed
            },
            decompress: { _, _, _ in Issue.record("Unexpected decompression") }
        )
        try await withDependencies {
            $0.devCommandClient = effects
            $0.keyValueStorage = ForbiddenAuthStorage()
            $0.zipCompressor = compressor
        } operation: {
            try await DevBuildCommand.parse(["--ipa"]).run()
        }
        #expect(await recorder.events == ["ipa"])
        #expect(try Data(contentsOf: directory.appendingPathComponent("App.ipa")) == Data("compressed app".utf8))
    }

    @Test func iosRunAndXcodeRetainLegacyPacking() async throws {
        struct BuildStopped: Error {}
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = Recorder()
        var effects = client(schema: .default, root: directory)
        effects.legacyPack = { triple, configuration, xcode in
            #expect(triple == "arm64-apple-ios")
            #expect(configuration == .debug)
            await recorder.record(xcode ? "xcode" : "run")
            throw BuildStopped()
        }
        await #expect(throws: BuildStopped.self) {
            try await withDependencies {
                $0.devCommandClient = effects
                $0.keyValueStorage = ForbiddenAuthStorage()
            } operation: {
                try await DevRunCommand.parse([]).run()
            }
        }
        await #expect(throws: BuildStopped.self) {
            try await withDependencies {
                $0.devCommandClient = effects
                $0.keyValueStorage = ForbiddenAuthStorage()
            } operation: {
                try await DevXcodeCommand.parse([]).run()
            }
        }
        #expect(await recorder.events == ["run", "xcode"])
    }

    @Test func iosSignStillRequiresAuthenticationBeforePacking() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let effects = client(schema: .default, root: directory)
        await #expect(throws: (any Error).self) {
            try await withDependencies {
                $0.devCommandClient = effects
                $0.keyValueStorage = MemoryKeyValueStorage()
            } operation: {
                try await DevBuildCommand.parse(["--sign"]).run()
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
