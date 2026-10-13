import Dependencies
import Foundation
import Testing
import Yams
@testable import PackLib

struct PackContractTests {
    private func schema(_ yaml: String) throws -> PackSchema {
        try PackSchema(validating: YAMLDecoder().decode(PackSchemaBase.self, from: yaml))
    }

    @Test func legacyConfigurationsRemainValid() throws {
        let examples = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Examples")
        let enumerator = try #require(FileManager.default.enumerator(at: examples, includingPropertiesForKeys: nil))
        var count = 0
        for case let url as URL in enumerator where url.lastPathComponent == "xtool.yml" {
            let config = try schema(String(contentsOf: url, encoding: .utf8))
            #expect(config.version == .v1)
            #expect(try ResolvedTarget.resolve(schema: config).platform == .iOS)
            count += 1
        }
        #expect(count > 0)
        let target = try ResolvedTarget.resolve()
        #expect(target.triple == "arm64-apple-ios")
        #expect(target.deploymentTarget == "13.0")
    }

    @Test func schemaVersionControlsNewFields() throws {
        #expect(throws: (any Error).self) {
            try schema("version: 1\norgID: test\ntarget: arm64-apple-macosx")
        }
        #expect(throws: (any Error).self) {
            try schema("version: 3\norgID: test")
        }
        #expect(throws: (any Error).self) {
            try schema("version: 2\norgID: test\nsource: {kind: prebuilt, path: helper, product: Wrong}")
        }
    }

    @Test func effectiveTargetAndDeploymentPrecedence() throws {
        let config = try schema("version: 2\norgID: test\ntarget: arm64-apple-macosx\ndeploymentTarget: '15.0'")
        let fromSchema = try ResolvedTarget.resolve(schema: config, packageDeploymentTargets: ["macos": "14.0"])
        #expect(fromSchema.platform == .macOS)
        #expect(fromSchema.compilerTriple == "arm64-apple-macosx15.0")
        let fromCLI = try ResolvedTarget.resolve(cliTarget: "x86_64-apple-ios17.0-simulator", schema: config)
        #expect(fromCLI.platform == .iOSSimulator)
        #expect(fromCLI.architecture == "x86_64")
        #expect(fromCLI.deploymentTarget == "17.0")
        let fromPackage = try ResolvedTarget.resolve(packageDeploymentTargets: ["ios": "16.0"])
        #expect(fromPackage.deploymentTarget == "16.0")
        #expect(throws: (any Error).self) {
            try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx14.0", schema: config)
        }
        #expect(throws: (any Error).self) {
            try ResolvedTarget.resolve(schema: config, packageDeploymentTargets: ["macos": "16.0"])
        }
    }

    @Test(arguments: ["unknown-triple", "arm64-apple-ios-macabi", "arm64-apple-tvos",
                      "x86_64-apple-ios", "arm64-apple-macosx-simulator", "arm64-apple-ios17..0",
                      "arm64-apple-macosx15.0-extra", "arm64--ios"])
    func unsupportedTriplesReject(triple: String) {
        #expect(throws: (any Error).self) { try TargetTriple(triple) }
    }

    @Test func versionTwoModelsExternalInputs() throws {
        let config = try schema("""
        version: 2
        orgID: test
        target: arm64-apple-macosx
        source: {kind: executable, product: App}
        entitlementsPath: ../signing/App.entitlements
        resourceCopies:
          - source: agent.plist
            destination: {location: contents, path: Library/LaunchAgents/test.agent.plist}
        nestedProducts:
          - product: Service
            kind: xpcService
            source: {kind: library, product: ServiceLibrary}
            infoPath: Service.plist
            entitlementsPath: /external/Service.entitlements
          - product: Helper
            kind: helperExecutable
            source: {kind: prebuilt, path: /external/helper}
        """)
        #expect(config.source == .executable(product: "App"))
        #expect(config.nestedProducts?.count == 2)
        #expect(config.nestedProducts?.last?.source == .prebuilt(path: "/external/helper"))
        #expect(config.entitlementsPath == "../signing/App.entitlements")
        #expect(try ResolvedTarget.resolve(schema: config).platform == .macOS)
        #expect(throws: (any Error).self) {
            try ResolvedTarget.resolve(cliTarget: "arm64-apple-ios", schema: config)
        }
    }

    @Test func layoutsMatchPlatformAndProductKind() throws {
        let app = BundleLayout(platform: .macOS, kind: .application, name: "App")
        #expect(app.executablePath == "Contents/MacOS/App")
        #expect(app.infoPlistPath == "Contents/Info.plist")
        #expect(app.resourcesPath == "Contents/Resources")
        #expect(app.frameworksPath == "Contents/Frameworks")
        #expect(try app.path(for: .init(location: .contents, path: "Library/LaunchAgents/agent.plist"))
                == "Contents/Library/LaunchAgents/agent.plist")
        let ext = BundleLayout(platform: .macOS, kind: .appExtension, name: "Preview")
        #expect(ext.executablePath == "Contents/PlugIns/Preview.appex/Contents/MacOS/Preview")
        let service = BundleLayout(platform: .macOS, kind: .xpcService, name: "Service")
        #expect(service.infoPlistPath == "Contents/XPCServices/Service.xpc/Contents/Info.plist")
        let helper = BundleLayout(platform: .macOS, kind: .helperExecutable, name: "Helper")
        #expect(helper.executablePath == "Contents/Helpers/Helper")
        #expect(helper.infoPlistPath == nil)
        let ios = BundleLayout(platform: .iOS, kind: .appExtension, name: "Extension")
        #expect(ios.executablePath == "PlugIns/Extension.appex/Extension")
        #expect(ios.resourcesPath == "PlugIns/Extension.appex")
    }

    @Test(arguments: ["", "/absolute", "../escape", "a/../../escape", "a//b", "a/./b", "a\\b", "a\0b"])
    func unsafeResourceDestinationsReject(path: String) {
        #expect(throws: (any Error).self) { try ResourceDestination(path: path).validate() }
    }

    private func product(_ name: String, kind: Plan.ProductType, target: ResolvedTarget) -> Plan.Product {
        Plan.Product(
            target: target,
            type: kind,
            product: name,
            bundleID: "test.\(name)",
            infoPlist: [:],
            resources: [],
            entitlementsPath: "/external/\(name).entitlements"
        )
    }

    @Test func signingManifestKeepsProductAssociations() throws {
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx")
        let plan = try Plan(
            target: target,
            app: product("App", kind: .application, target: target),
            extensions: [product("Preview", kind: .appExtension, target: target)],
            nestedProducts: [product("Service", kind: .xpcService, target: target),
                             product("Helper", kind: .helperExecutable, target: target)]
        )
        let data = try JSONEncoder().encode(DeferredSigningManifest(plan: plan))
        let manifest = try JSONDecoder().decode(DeferredSigningManifest.self, from: data)
        #expect(manifest.version == 1)
        #expect(manifest.status == .deferred)
        #expect(manifest.target == target)
        #expect(manifest.products.count == 4)
        #expect(manifest.products[2].bundlePath == "Contents/XPCServices/Service.xpc")
        #expect(manifest.products[2].entitlementsPath == "/external/Service.entitlements")
        #expect(manifest.products[3].executablePath == "Contents/Helpers/Helper")
    }

    @Test func inconsistentPlansReject() throws {
        let ios = try ResolvedTarget.resolve()
        let mac = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx")
        #expect(throws: (any Error).self) {
            try Plan(target: ios, app: product("App", kind: .application, target: mac))
        }
        #expect(throws: (any Error).self) {
            try Plan(target: ios, app: product("App", kind: .application, target: ios),
                     extensions: [product("App", kind: .appExtension, target: ios)])
        }
    }

    @Test func packerUsesInjectedBuilder() async throws {
        struct BuildStopped: Error {}
        let target = try ResolvedTarget.resolve()
        let plan = try Plan(target: target, app: product("App", kind: .application, target: target))
        let settings = try await BuildSettings(configuration: .debug, triple: target.triple, buildSystem: .swiftPM)
        await #expect(throws: BuildStopped.self) {
            try await withDependencies {
                $0.productBuilder = ProductBuilderClient { _, _ in throw BuildStopped() }
            } operation: {
                try await Packer(buildSettings: settings, plan: plan).pack()
            }
        }
    }

    @Test func macOSXcodeGenerationRejectsBeforeWriting() async throws {
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx")
        let plan = try Plan(target: target, app: product("App", kind: .application, target: target))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: (any Error).self) {
            try await XcodePacker(plan: plan).createProject(at: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
