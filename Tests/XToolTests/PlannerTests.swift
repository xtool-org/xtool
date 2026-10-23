import Dependencies
import Foundation
import Testing
import Yams
@testable import PackLib

struct PlannerTests {
    private struct Package: Sendable {
        let description: Data
        let manifest: Data
    }

    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    private func package(
        _ name: String = "Root", products: [[String: Any]]? = nil, targets: [[String: Any]]? = nil,
        dependencies: [[String: Any]] = [], platforms: [[String: String]] = [], path: String? = nil
    ) throws -> Package {
        let targets = targets ?? [target("App")]
        return try Package(
            description: json([
                "name": name, "path": path as Any? ?? NSNull(), "products": products ?? [product("App")],
                "platforms": platforms, "targets": targets.map { target -> [String: Any] in
                    var described = target
                    described.removeValue(forKey: "dependencies")
                    return described
                },
            ]),
            manifest: json(["targets": targets, "dependencies": dependencies])
        )
    }

    private func product(_ name: String, kind: String = "automatic", target: String? = nil) -> [String: Any] {
        ["name": name, "targets": [target ?? name],
         "type": kind == "executable" ? ["executable": NSNull()] : ["library": [kind]]]
    }

    private func target(
        _ name: String, kind: String = "regular", resources: Bool = false, dependencies: [[String: Any]] = []
    ) -> [String: Any] {
        ["name": name, "type": kind, "module_type": kind == "binary" ? "BinaryTarget" : "SwiftTarget",
         "resources": resources ? [["path": "message.txt"]] : [], "dependencies": dependencies]
    }

    private func reference(_ identity: String, alias: String? = nil) -> [String: Any] {
        var value = ["identity": identity]
        value["nameForTargetDependencyResolutionOnly"] = alias
        return ["fileSystem": [value]]
    }

    private func dependency(_ name: String, package: String? = nil, platforms: [String]? = nil) -> [String: Any] {
        let condition: Any = platforms.map { ["platformNames": $0] } ?? NSNull()
        return ["product": [name, package as Any? ?? NSNull(), NSNull(), condition]]
    }

    private func configuration(_ text: String = "") throws -> PackSchema {
        try PackSchema(validating: YAMLDecoder().decode(PackSchemaBase.self, from: "version: 2\norgID: test\n" + text))
    }

    private func plan(
        _ packages: [String: Package], schema: PackSchema = .default, triple: String = "arm64-apple-ios",
        clientOverride: PackageInspectionClient? = nil
    ) async throws -> Plan {
        let dependencyTree = try json([
            "identity": "root", "path": "/root", "dependencies": packages.keys.filter { $0 != "root" }.map {
                ["identity": $0, "path": "/\($0)", "dependencies": []] as [String: Any]
            },
        ])
        let client = PackageInspectionClient(
            dependencies: { _ in dependencyTree },
            describe: { settings in try #require(packages[URL(fileURLWithPath: settings.packagePath).lastPathComponent]).description },
            manifest: { settings in try #require(packages[URL(fileURLWithPath: settings.packagePath).lastPathComponent]).manifest }
        )
        let settings = try await BuildSettings(configuration: .release, triple: triple, buildSystem: .swiftPM, packagePath: "/root")
        return try await withDependencies {
            $0.packageInspection = clientOverride ?? client
        } operation: {
            try await Planner(buildSettings: settings, schema: schema).createPlan()
        }
    }

    @Test func inspectionConcurrencyIsBounded() async throws {
        actor Gauge {
            var current = 0, peak = 0
            func enter() { current += 1; peak = max(peak, current) }
            func leave() { current -= 1 }
        }
        let gauge = Gauge()
        let names = (0..<(Planner.inspectionLimit * 3)).map { "dep\($0)" }
        let root = try package()
        let dependencyTree = try json([
            "identity": "root", "path": "/root",
            "dependencies": names.map { ["identity": $0, "path": "/\($0)", "dependencies": []] as [String: Any] },
        ])
        let client = PackageInspectionClient(
            dependencies: { _ in dependencyTree },
            describe: { _ in
                await gauge.enter()
                try await Task.sleep(for: .milliseconds(5))
                await gauge.leave()
                return root.description
            },
            manifest: { _ in root.manifest }
        )
        _ = try await plan(["root": root], clientOverride: client)
        #expect(await gauge.peak <= Planner.inspectionLimit)
        #expect(await gauge.peak > 1)
    }

    @Test func pinnedDependencyInspectionIsReused() async throws {
        actor Calls {
            var paths: [String] = []
            func record(_ path: String) { paths.append(path) }
            func take() -> [String] { defer { paths = [] }; return paths.sorted() }
        }
        let calls = Calls()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let packages = try [root.path: package(), "/pinned": package("Pinned"), "/local": package("Local")]
        func plan(version: String) async throws {
            let tree = try json([
                "identity": "root", "url": root.path, "version": "unspecified", "path": root.path, "dependencies": [
                    ["identity": "pinned", "url": "https://example.com/pinned", "version": version, "traits": ["default"],
                     "path": "/pinned", "dependencies": []] as [String: Any],
                    ["identity": "local", "url": "/local", "version": "unspecified", "path": "/local", "dependencies": []],
                ],
            ])
            let client = PackageInspectionClient(
                dependencies: { _ in tree },
                describe: { settings in
                    await calls.record(settings.packagePath)
                    return try #require(packages[settings.packagePath]).description
                },
                manifest: { settings in try #require(packages[settings.packagePath]).manifest },
                toolchain: { "6.2.0" }
            )
            let settings = try await BuildSettings(configuration: .release, triple: "arm64-apple-ios", buildSystem: .swiftPM,
                                                   packagePath: root.path)
            _ = try await withDependencies {
                $0.packageInspection = client
            } operation: {
                try await Planner(buildSettings: settings, schema: .default).createPlan()
            }
        }
        try await plan(version: "1.0.0")
        #expect(await calls.take() == ["/local", "/pinned", root.path].sorted())
        try await plan(version: "1.0.0")
        #expect(await calls.take() == ["/local", root.path].sorted())
        try await plan(version: "1.1.0")
        #expect(await calls.take() == ["/local", "/pinned", root.path].sorted())
    }

    @Test func sameNamedTargetsInDifferentPackagesBothContributeResources() async throws {
        let root = try package(targets: [target("App", dependencies: [
            dependency("First", package: "one"), dependency("Second", package: "two"),
        ])], dependencies: [reference("one"), reference("two")])
        let one = try package("FirstPackage", products: [product("First", target: "Shared")],
                              targets: [target("Shared", resources: true)])
        let two = try package("SecondPackage", products: [product("Second", target: "Shared")],
                              targets: [target("Shared", resources: true)])
        let app = try await plan(["root": root, "one": one, "two": two]).app
        #expect(Set(app.resources) == [.bundle(package: "FirstPackage", target: "Shared"),
                                       .bundle(package: "SecondPackage", target: "Shared")])
    }

    @Test(arguments: ["arm64-apple-macosx", "arm64-apple-ios", "x86_64-apple-ios-simulator"])
    func conditionsUseTargetRatherThanHost(triple: String) async throws {
        let root = try package(targets: [target("App", dependencies: [
            dependency("MacLibrary", package: "mac", platforms: ["macos"]),
            dependency("IOSLibrary", package: "ios", platforms: ["ios"]),
            dependency("MissingHostLibrary", package: "absent", platforms: ["linux"]),
            ["target": ["MacLocal", ["platformNames": ["macos"]]]],
            ["byName": ["IOSLocal", ["platformNames": ["ios"]]]],
        ]), target("MacLocal", resources: true), target("IOSLocal", resources: true)],
                               dependencies: [reference("mac"), reference("ios")])
        let mac = try package("Mac", products: [product("MacLibrary", kind: "dynamic")],
                              targets: [target("MacLibrary", resources: true)])
        let ios = try package("IOS", products: [product("IOSLibrary", kind: "static")],
                              targets: [target("IOSLibrary", resources: true)])
        let app = try await plan(["root": root, "mac": mac, "ios": ios], triple: triple).app
        if app.platform == .macOS {
            #expect(Set(app.resources) == [.bundle(package: "Root", target: "MacLocal"),
                                           .bundle(package: "Mac", target: "MacLibrary"), .library(name: "MacLibrary")])
        } else {
            #expect(Set(app.resources) == [.bundle(package: "Root", target: "IOSLocal"),
                                           .bundle(package: "IOS", target: "IOSLibrary")])
        }
    }

    @Test func macroDependenciesNeverContributeResourcesOrResolveHostProducts() async throws {
        let root = try package(targets: [target("App", dependencies: [["target": ["Macro", NSNull()]]]),
                                         target("Macro", kind: "macro", resources: true, dependencies: [
                                            dependency("SwiftSyntaxMacros", package: "host-only"),
                                         ])])
        #expect(try await plan(["root": root]).app.resources.isEmpty)
    }

    @Test(arguments: ["automatic", "static", "dynamic", "executable"])
    func explicitProductSelectionResolvesSourceKinds(kind: String) async throws {
        let root = try package(products: [product("Selected", kind: kind), product("Other")],
                               targets: [target("Selected"), target("Other")])
        let app = try await plan(["root": root], schema: configuration("product: Selected")).app
        #expect(app.product == "Selected")
        #expect(app.resources == (kind == "dynamic" ? [.library(name: "Selected")] : []))
        #expect(app.resolvedSource == (kind == "executable" ? .executable(product: "Selected") : .library(product: "Selected")))
    }

    @Test func explicitSourceAllowsDistinctBundleName() async throws {
        let root = try package(products: [product("CLI", kind: "executable")], targets: [target("CLI")])
        let app = try await plan(["root": root], schema: configuration("""
        product: BundleName
        source: {kind: executable, product: CLI}
        """)).app
        #expect(app.product == "BundleName")
        #expect(app.resolvedSource == .executable(product: "CLI"))
        #expect(app.infoPlist["CFBundleExecutable"] as? String == "BundleName")
    }

    @Test func macOSDefaultsUseSelectedPackageDeploymentAndExcludeIOSKeys() async throws {
        let root = try package(platforms: [["name": "ios", "version": "19.0"], ["name": "macos", "version": "16.2"]])
        let app = try await plan(["root": root], triple: "arm64-apple-macosx").app
        #expect(app.deploymentTarget == "16.2")
        #expect(app.infoPlist["LSMinimumSystemVersion"] as? String == "16.2")
        for key in ["MinimumOSVersion", "UIDeviceFamily", "UISupportedInterfaceOrientations", "UILaunchScreen"] {
            #expect(app.infoPlist[key] == nil)
        }
    }

    private func plist(_ dictionary: Any, in root: URL, name: String) throws -> String {
        let url = root.appendingPathComponent(name + ".plist")
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: url)
        return url.path
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func legacyIOSLibraryAndPlistOverridesRemainSupported() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try plist(["CFBundleIdentifier": "custom.identity", "CFBundleDisplayName": "Custom Name",
                              "UIDeviceFamily": [2], "MinimumOSVersion": "17.0", "NSExtension": ["Custom": true]],
                             in: directory, name: "App")
        let schema = try PackSchema(validating: .init(version: .v1, orgID: "test", infoPath: path))
        let app = try await plan(["root": package(platforms: [["name": "ios", "version": "16.0"]])], schema: schema).app
        #expect(app.resolvedSource == .library(product: "App"))
        #expect(app.bundleID == "custom.identity")
        #expect(app.infoPlist["CFBundleDisplayName"] as? String == "Custom Name")
        #expect(app.infoPlist["MinimumOSVersion"] as? String == "17.0")
        #expect(app.infoPlist["UIDeviceFamily"] as? [Int] == [2])
        #expect(app.infoPlist["NSExtension"] as? [String: Bool] == ["Custom": true])
        #expect(app.infoPlist["UILaunchScreen"] != nil)
    }

    @Test func nestedProductsRetainCallerDictionariesAndSources() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appPlist = try plist(["CFBundleIdentifier": "caller.App"], in: directory, name: "App")
        let extPlist = try plist(
            ["CFBundleIdentifier": "caller.Extension", "NSExtension": ["NSExtensionPointIdentifier": "test"]],
            in: directory, name: "Extension"
        )
        let servicePlist = try plist(
            ["XPCService": ["ServiceType": "Application", "RunLoopType": "dispatch_main"]],
            in: directory, name: "Service"
        )
        let schema = try configuration("""
        product: App
        infoPath: \(appPlist)
        extensions:
          - product: Extension
            source: {kind: library, product: ExtensionLibrary}
            infoPath: \(extPlist)
        nestedProducts:
          - product: Service
            kind: xpcService
            source: {kind: executable, product: ServiceExecutable}
            infoPath: \(servicePlist)
          - product: Helper
            kind: helperExecutable
            source: {kind: prebuilt, path: /external/helper}
            entitlementsPath: /external/helper.entitlements
        """)
        let root = try package(products: [product("App"), product("ExtensionLibrary"),
                                         product("ServiceExecutable", kind: "executable")],
                               targets: [target("App"), target("ExtensionLibrary"), target("ServiceExecutable")])
        let plan = try await plan(["root": root], schema: schema, triple: "arm64-apple-macosx")
        #expect(plan.extensions[0].bundleID == "caller.Extension")
        #expect(plan.extensions[0].infoPlist["NSExtension"] as? [String: String] == ["NSExtensionPointIdentifier": "test"])
        #expect(plan.nestedProducts[0].bundleID == "caller.App.Service")
        #expect(plan.nestedProducts[0].infoPlist["XPCService"] as? [String: String]
                == ["ServiceType": "Application", "RunLoopType": "dispatch_main"])
        #expect(plan.nestedProducts[1].resolvedSource == .prebuilt(path: "/external/helper"))
        #expect(plan.nestedProducts[1].entitlementsPath == "/external/helper.entitlements")
        #expect(plan.allProducts.allSatisfy { $0.target == plan.target })
    }

    @Test func resourcesAreDeduplicatedAndExplicitDestinationsSurvive() async throws {
        let root = try package(targets: [target("App", resources: true, dependencies: [
            ["target": ["Local", NSNull()]], ["byName": ["Local", NSNull()]], ["target": ["Binary", NSNull()]],
        ]), target("Local", resources: true), target("Binary", kind: "binary")])
        let schema = try configuration("""
        resources: [Assets]
        resourceCopies:
          - source: agent.plist
            destination: {location: contents, path: Library/LaunchAgents/agent.plist}
        """)
        let app = try await plan(["root": root], schema: schema, triple: "arm64-apple-macosx").app
        #expect(app.resources.count == 5)
        #expect(Set(app.resources) == [.bundle(package: "Root", target: "App"), .bundle(package: "Root", target: "Local"),
                                       .binaryTarget(name: "Binary"), .root(source: "Assets"),
                                       .copy(.init(source: "agent.plist", destination: .init(
                                        location: .contents, path: "Library/LaunchAgents/agent.plist")))])
        #expect(app.resources.contains(.binaryTarget(name: "Binary")))
    }

    @Test func localXCFrameworkBinaryTargetsRecordTheirPath() async throws {
        func binary(_ name: String, path: String) -> [String: Any] {
            var value = target(name, kind: "binary")
            value["path"] = path
            return value
        }
        let root = try package(targets: [
            target("App", dependencies: [["target": ["Local", NSNull()]], ["target": ["Zipped", NSNull()]]]),
            binary("Local", path: "Vendor/Local.xcframework"), binary("Zipped", path: "Vendor/Zipped.zip"),
        ], path: "/root")
        let app = try await plan(["root": root], triple: "arm64-apple-macosx").app
        #expect(Set(app.resources) == [.binaryTarget(name: "Local", xcframework: "/root/Vendor/Local.xcframework"),
                                       .binaryTarget(name: "Zipped")])
    }

    @Test func packageAliasesDisambiguateSameNamedProducts() async throws {
        let root = try package(targets: [target("App", dependencies: [dependency("Shared", package: "Alias")])],
                               dependencies: [reference("one", alias: "Alias"), reference("two")])
        let one = try package("One", products: [product("Shared")], targets: [target("Shared", resources: true)])
        let two = try package("Two", products: [product("Shared")], targets: [target("Shared", resources: true)])
        #expect(try await plan(["root": root, "one": one, "two": two]).app.resources == [.bundle(package: "One", target: "Shared")])
    }

    @Test(arguments: ["product: Missing", "source: {kind: executable, product: App}",
                      "source: {kind: library, product: Missing}", "source: {kind: executable, product: ../escape}"])
    func invalidProductSelectionsReject(text: String) async throws {
        await #expect(throws: (any Error).self) {
            try await plan(["root": package()], schema: configuration(text))
        }
    }

    @Test func ambiguousLibrariesMissingTargetsAndWrongPlistTypesReject() async throws {
        let ambiguous = try package(products: [product("App"), product("Other")], targets: [target("App"), target("Other")])
        await #expect(throws: (any Error).self) { try await plan(["root": ambiguous]) }
        let missing = try package(targets: [])
        await #expect(throws: (any Error).self) { try await plan(["root": missing]) }
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try plist(["not a dictionary"], in: directory, name: "Invalid")
        await #expect(throws: (any Error).self) {
            try await plan(["root": package()], schema: configuration("infoPath: \(path)"))
        }
    }

    #if os(macOS)
    @Test func liveSwiftPMInspectionPreservesConditionsAndAliases() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ contents: String, path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "LivePlanner", platforms: [.macOS("16.0"), .iOS("19.0")],
            products: [.executable(name: "CLI", targets: ["Entry"])],
            dependencies: [.package(name: "SupportAlias", path: "Dependency")],
            targets: [
                .executableTarget(name: "Entry", dependencies: [
                    .target(name: "IOSOnly", condition: .when(platforms: [.iOS])),
                    .product(name: "SupportLibrary", package: "SupportAlias", condition: .when(platforms: [.macOS])),
                ]),
                .target(name: "IOSOnly", resources: [.copy("message.txt")]),
            ]
        )
        """, path: "Package.swift")
        try write("print(\"fixture\")", path: "Sources/Entry/main.swift")
        try write("public struct IOSOnly {}", path: "Sources/IOSOnly/IOSOnly.swift")
        try write("ios resource", path: "Sources/IOSOnly/message.txt")
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Support", products: [.library(name: "SupportLibrary", targets: ["Support"])],
                              targets: [.target(name: "Support", resources: [.copy("message.txt")])])
        """, path: "Dependency/Package.swift")
        try write("public struct Support {}", path: "Dependency/Sources/Support/Support.swift")
        try write("mac resource", path: "Dependency/Sources/Support/message.txt")
        let settings = try await BuildSettings(configuration: .release, triple: "arm64-apple-macosx", buildSystem: .swiftPM,
                                               packagePath: root.path)
        let schema = try configuration("product: CLI")
        let plan = try await withDependencies {
            $0.packageInspection = .liveValue
        } operation: {
            try await Planner(buildSettings: settings, schema: schema).createPlan()
        }
        #expect(plan.app.resolvedSource == .executable(product: "CLI"))
        #expect(plan.app.deploymentTarget == "16.0")
        #expect(plan.app.resources == [.bundle(package: "Support", target: "Support")])
    }
    #endif

}
