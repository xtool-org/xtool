import Foundation
import XUtils
import Subprocess

public struct Planner: Sendable {
    public var buildSettings: BuildSettings
    public var schema: PackSchema

    public init(
        buildSettings: BuildSettings,
        schema: PackSchema
    ) {
        self.buildSettings = buildSettings
        self.schema = schema
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // anything older than this requires bundling the stdlib which
    // is doable but probably not worth the effort
    private static let minSupportedIOSVersion = "13.0"

    private func buildGraph() async throws -> PackageGraph {
        let dependencyRoot = try await dumpDependencies()

        let packages = try await withThrowingTaskGroup(
            of: (PackageDependency, PackageDump).self,
            returning: [String: PackageDump].self
        ) { group in
            var visited: Set<String> = []
            var dependencies: [PackageDependency] = [dependencyRoot]
            while let dependencyNode = dependencies.popLast() {
                guard visited.insert(dependencyNode.identity).inserted else { continue }
                dependencies.append(contentsOf: dependencyNode.dependencies)
                group.addTask { (dependencyNode, try await dumpPackage(at: dependencyNode.path)) }
            }

            var packages: [String: PackageDump] = [:]
            while let result = await group.nextResult() {
                switch result {
                case .success((let dependency, let dump)):
                    packages[dependency.identity] = dump
                case .failure(_ as CancellationError):
                    // continue loop
                    break
                case .failure(let error):
                    group.cancelAll()
                    throw error
                }
            }

            return packages
        }

        var packagesByProductName: [String: String] = [:]
        for (packageID, package) in packages {
            for product in package.products ?? [] {
                packagesByProductName[product.name] = packageID
            }
        }

        let rootPackage = packages[dependencyRoot.identity]!

        return PackageGraph(
            root: rootPackage,
            packages: packages,
            packagesByProductName: packagesByProductName
        )
    }

    public func createPlan() async throws -> Plan {
        // TODO: cache plan using (Package.swift+Package.resolved) as the key?

        let graph = try await buildGraph()

        let app = try await product(
            from: graph,
            matching: schema.product,
            type: .application,
            plist: schema.infoPath,
            idSpecifier: schema.idSpecifier,
            iconPath: schema.iconPath,
            rootResources: schema.resources,
            entitlementsPath: schema.entitlementsPath
        )

        let extensionProducts: [Plan.Product]
        if let extensions = schema.extensions, !extensions.isEmpty {
            extensionProducts = try await withThrowingTaskGroup(of: Plan.Product.self) { group in
                for ext in extensions {
                    group.addTask {
                        try await product(
                            from: graph,
                            matching: ext.product,
                            type: .appExtension,
                            plist: ext.infoPath,
                            idSpecifier: ext.bundleID.flatMap(PackSchema.IDSpecifier.bundleID) ?? .orgID(app.bundleID),
                            iconPath: nil,
                            rootResources: ext.resources,
                            entitlementsPath: ext.entitlementsPath
                        )
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
        } else {
            extensionProducts = []
        }

        let xcTest = xcTestPlan(from: graph, app: app)

        return Plan(app: app, extensions: extensionProducts, xcTest: xcTest)
    }

    /// SwiftPM combines every test target in the root package into a single `<packageName>
    /// PackageTests` product (confirmed by reading SwiftPM's own source -- there is no
    /// per-target test product). Rather than an artificial split, this mirrors that: one
    /// combined `.xctest` bundle, with per-target/per-method selection handled at runtime via
    /// `XCTestConfiguration.testsToRun`/`testsToSkip` (`xcodebuild -only-testing:`'s equivalent),
    /// not by building separate bundles.
    ///
    /// - Important: confirmed against a real Darwin SDK (`swift build --build-tests --swift-sdk
    ///   arm64-apple-ios`) that if a test target depends (even transitively) on the same library
    ///   product wrapped as the app (`schema.product`/`app.product`), and that library contains
    ///   the app's `@main` entry point -- which is exactly how xtool's own app-wrapping model
    ///   requires it to be structured, see `product(from:matching:type:...)` above -- the combined
    ///   test product fails to link with a `duplicate symbol: main` error, because SwiftPM
    ///   statically links the test product against everything the test target depends on
    ///   (including that `@main`) while *also* generating its own XCTest bootstrap `main`. Real
    ///   Xcode sidesteps this because unit tests get dlopen'd into an already-running host
    ///   process rather than statically linked into a fresh executable; SwiftPM's package-testing
    ///   model has no equivalent. Not fixed here -- needs either user-facing guidance (keep
    ///   `@main` in a target the test target doesn't depend on, which is Apple's own recommended
    ///   SwiftPM structure anyway) or a build-graph-level fix, tracked as an open item.
    private func xcTestPlan(from graph: PackageGraph, app: Plan.Product) -> Plan.XCTestPlan? {
        let testTargets = (graph.root.targets ?? []).filter(\.isTestTarget)
        guard !testTargets.isEmpty else { return nil }

        let deploymentTarget = graph.root.platforms?.first { $0.name == "ios" }?.version
            ?? Self.minSupportedIOSVersion

        return Plan.XCTestPlan(
            packageName: graph.root.name,
            // Deliberately *not* derived from `app.bundleID`: a free/personal Apple Developer
            // account is capped at a small number of new App ID registrations per rolling 7-day
            // window, and deriving this per-app would silently cost every new project tested an
            // extra registration on top of the app's own. One xtool install only ever tests one
            // app at a time anyway, so a single shared runner ID (still team-scoped by
            // `ProvisioningIdentifiers.identifier(fromSanitized:context:)`, so it doesn't collide
            // across different developers/teams) is reused across every project instead.
            bundleID: "xtool.xctrunner",
            deploymentTarget: deploymentTarget,
            entitlementsPath: schema.entitlementsPath,
            testTargetNames: testTargets.map(\.name),
            testTargetPaths: Dictionary(uniqueKeysWithValues: testTargets.compactMap { target in
                target.path.map { (target.name, $0) }
            })
        )
    }

    // swiftlint:disable cyclomatic_complexity function_parameter_count
    private func product(
        from graph: PackageGraph,
        matching name: String?,
        type: Plan.ProductType,
        plist: String?,
        idSpecifier: PackSchema.IDSpecifier,
        iconPath: String?,
        rootResources: [String]?,
        entitlementsPath: String?
    ) async throws -> Plan.Product {
        let library = try selectLibrary(
            from: graph.root.products?.filter { $0.type == .autoLibrary } ?? [],
            matching: name
        )
        var resources: [Plan.Resource] = []
        var visited: Set<String> = []
        var targets = library.targets.map { (graph.root, $0) }
        while let (targetPackage, targetName) = targets.popLast() {
            guard let target = targetPackage.targets?.first(where: { $0.name == targetName }) else {
                throw StringError("Could not find target '\(targetName)' in package '\(targetPackage.name)'")
            }
            guard visited.insert(targetName).inserted else { continue }
            if target.moduleType == "BinaryTarget" {
                resources.append(.binaryTarget(name: targetName))
            }
            if target.resources?.isEmpty == false {
                resources.append(.bundle(package: targetPackage.name, target: targetName))
            }
            for targetName in (target.targetDependencies ?? []) {
                targets.append((targetPackage, targetName))
            }
            for productName in (target.productDependencies ?? []) {
                let (package, product) = try graph.product(name: productName)
                if product.type == .dynamicLibrary {
                    resources.append(.library(name: productName))
                }
                targets.append(contentsOf: product.targets.map { (package, $0) })
            }
        }

        if let rootResources {
            resources += rootResources.map { .root(source: $0) }
        }

        let bundleID = idSpecifier.formBundleID(product: library.name)
        let deploymentTarget = graph.root.platforms?.first { $0.name == "ios" }?.version
            ?? Self.minSupportedIOSVersion

        var infoPlist: [String: Sendable] = [
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0.0",
            "MinimumOSVersion": deploymentTarget,
            "CFBundleIdentifier": bundleID,
            "CFBundleName": library.name,
            "CFBundleExecutable": library.name,
            "CFBundleDisplayName": library.name,
            "CFBundlePackageType": type.fourCharCode,
        ]

        switch type {
        case .application:
            infoPlist["UIDeviceFamily"] = [1, 2]
            infoPlist["UISupportedInterfaceOrientations"] = ["UIInterfaceOrientationPortrait"]
            infoPlist["UISupportedInterfaceOrientations~ipad"] = [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight",
            ]
            infoPlist["UILaunchScreen"] = [:] as [String: Sendable]
        case .appExtension:
            // Should set default parameters?
            infoPlist["NSExtension"] = [:] as [String: Sendable]
        }

        if let plist {
            let data = try await Data(reading: URL(fileURLWithPath: plist))
            let info = try PropertyListSerialization.propertyList(from: data, format: nil)
            if let info = info as? [String: Sendable] {
                infoPlist.merge(info, uniquingKeysWith: { $1 })
            } else {
                throw StringError("Info.plist has invalid format: expected a dictionary.")
            }
        }

        return Plan.Product(
            type: type,
            product: library.name,
            deploymentTarget: deploymentTarget,
            bundleID: bundleID,
            infoPlist: infoPlist,
            resources: resources,
            iconPath: iconPath,
            entitlementsPath: entitlementsPath
        )
    }

    private func dumpDependencies() async throws -> PackageDependency {
        let tempDir = try TemporaryDirectory(name: "xtool-dump")
        let tempFileURL = tempDir.url.appendingPathComponent("dump.json")

        // SwiftPM sometimes prints extraneous data to stdout, so ask
        // it to write the JSON to a temp file instead. See:
        // https://github.com/xtool-org/xtool/pull/97#discussion_r2203618825
        _ = try await _dumpAction(
            arguments: ["-q", "show-dependencies", "--format", "json", "-o", tempFileURL.path],
            path: buildSettings.packagePath
        )

        return try Self.decoder.decode(
            PackageDependency.self,
            from: Data(contentsOf: tempFileURL)
        )
    }

    private func dumpPackage(at path: String) async throws -> PackageDump {
        let data = try await _dumpAction(arguments: ["-q", "describe", "--type", "json"], path: path)
        try Task.checkCancellation()

        // As in dumpDependencies, we may end up with extraneous data, but `describe`
        // doesn't have a `-o` flag for a clean workaround. Resort to a heuristic,
        // looking for the opening brace.
        let fromBrace = data.drop(while: { $0 != Character("{").asciiValue })
        return try Self.decoder.decode(PackageDump.self, from: fromBrace)
    }

    private func _dumpAction(arguments: [String], path: String) async throws -> Data {
        let dumpConfig = try await buildSettings.swiftPMInvocation(
            forTool: "package",
            arguments: arguments,
            packagePathOverride: path
        )
        return try await Subprocess.run(
            dumpConfig,
            output: .data(limit: .max),
            error: .currentStandardError,
        )
        .checkSuccess()
        .standardOutput
    }

    private func selectLibrary(
        from products: [PackageDump.Product],
        matching name: String?
    ) throws -> PackageDump.Product {
        switch products.count {
        case 0:
            throw StringError("No library products were found in the package")
        case 1:
            let product = products[0]
            if let name, product.name != name {
                throw StringError("""
                Product name ('\(product.name)') does not match the 'product' value in the schema ('\(name)')
                """)
            }
            return product
        default:
            guard let name else {
                throw StringError("""
                Multiple library products were found (\(products.map(\.name))). Please either:
                1) Expose exactly one library product, or
                2) Specify the product you want via the 'product' key in xtool.yml.
                """)
            }
            guard let product = products.first(where: { $0.name == name }) else {
                throw StringError("""
                Schema declares a 'product' name of '\(name)' but no matching product was found.
                Found: \(products.map(\.name)).
                """)
            }
            return product
        }
    }
}

public struct Plan: Sendable {
    public var app: Product
    public var extensions: [Product]
    /// Non-nil when the package has at least one SwiftPM test target. See `Planner.xcTestPlan`
    /// for why this isn't folded into `allProducts`/`Product` -- building and packaging it is a
    /// meaningfully different process (drives `swift build --build-tests` on the real package
    /// rather than the synthesized per-product wrapper package `Packer` otherwise always uses).
    public var xcTest: XCTestPlan?

    public var allProducts: [Product] {
        [app] + extensions
    }

    /// Describes the combined XCTest bundle (all test targets in the package) and the `Runner.app`
    /// synthesized to host it, mirroring Xcode's `<Target>-Runner.app` convention.
    public struct XCTestPlan: Sendable {
        public var packageName: String
        public var bundleID: String
        public var deploymentTarget: String
        public var entitlementsPath: String?
        /// Every SwiftPM `.testTarget` in the root package (e.g. `["MyAppTests", "MyAppUITests"]`)
        /// -- still built into one combined `.xctest` bundle (see `testProductName`'s doc comment
        /// for why SwiftPM leaves no alternative), but exposed separately so a caller (`xtool
        /// test`) can let the user pick one to actually run.
        public var testTargetNames: [String]
        /// Resolved source directory per test target name (e.g. `["MyAppTests":
        /// "Sources/MyAppTests"]`), used to scope a chosen target down to its actual `XCTestCase`
        /// class names for `testsToRun` filtering. A bare module name is *not* a valid
        /// `XCTTestIdentifier` on its own -- confirmed against real hardware (this session): it
        /// silently matches zero tests rather than "everything in that module" (unlike
        /// `xcodebuild -only-testing:ModuleName`, which is a distinct, higher-level filter xtool
        /// doesn't have access to here) -- so per-target selection instead expands to every
        /// `XCTestCase` subclass whose source file lives under this path.
        public var testTargetPaths: [String: String]

        /// SwiftPM's own product name for the combined test bundle (`<packageName>PackageTests`).
        public var testProductName: String { "\(packageName)PackageTests" }
        /// Name of the runner's own synthesized executable target/product.
        public var runnerProduct: String { "\(packageName)XCTRunner" }
    }

    public enum Resource: Codable, Sendable, Hashable {
        case bundle(package: String, target: String)
        case binaryTarget(name: String)
        case library(name: String)
        case root(source: String)
    }

    public struct Product: Sendable {
        public var type: ProductType
        public var product: String
        public var deploymentTarget: String
        public var bundleID: String
        public var infoPlist: [String: any Sendable]
        public var resources: [Resource]
        public var iconPath: String?
        public var entitlementsPath: String?

        public var targetName: String {
            "\(self.product)-\(self.type.targetSuffix)"
        }

        public func directory(inApp baseDir: URL) -> URL {
            switch type {
            case .application:
                baseDir
                    .appendingPathComponent(".", isDirectory: true)
            case .appExtension:
                baseDir
                    .appendingPathComponent("PlugIns", isDirectory: true)
                    .appendingPathComponent(product, isDirectory: true)
                    .appendingPathExtension("appex")
            }
        }
    }

    public enum ProductType: Sendable {
        case application
        case appExtension

        fileprivate var targetSuffix: String {
            switch self {
            case .application: "App"
            case .appExtension: "Extension"
            }
        }

        fileprivate var fourCharCode: String {
            switch self {
            case .application: "APPL"
            case .appExtension: "XPC!"
            }
        }
    }
}

private struct PackageDependency: Decodable {
    let identity: String
    let name: String
    let path: String // on disk
    let dependencies: [PackageDependency]
}

private struct PackageDump: Decodable {
    enum ProductType: Decodable {
        case executable
        case dynamicLibrary
        case staticLibrary
        case autoLibrary
        case other

        private enum CodingKeys: String, CodingKey {
            case executable
            case library
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.executable) {
                self = .executable
            } else if let library = try container.decodeIfPresent([String].self, forKey: .library) {
                if library.count == 1 {
                    switch library[0] {
                    case "dynamic":
                        self = .dynamicLibrary
                    case "static":
                        self = .staticLibrary
                    case "automatic":
                        self = .autoLibrary
                    default:
                        self = .other
                    }
                } else {
                    self = .other
                }
            } else {
                self = .other
            }
        }
    }

    struct Product: Decodable {
        let name: String
        let targets: [String]
        let type: ProductType
    }

    struct Target: Decodable {
        let name: String
        let moduleType: String
        // SwiftPM's `describe --type json` reports this as "type": "test"/"library"/"executable"/etc,
        // distinct from moduleType ("SwiftTarget"/"ClangTarget"/etc). Only "test" is checked today.
        let type: String?
        let productDependencies: [String]?
        let targetDependencies: [String]?
        let resources: [Resource]?
        /// Resolved source directory (e.g. `Sources/MyAppTests`) -- SwiftPM allows test targets
        /// under either `Sources/<name>` or `Tests/<name>`, so this is read from `describe`'s own
        /// resolved value rather than assumed.
        let path: String?

        var isTestTarget: Bool { type == "test" }
    }

    struct Resource: Decodable {
        let path: String
    }

    struct Platform: Decodable {
        let name: String
        let version: String
    }

    let name: String
    let products: [Product]?
    let targets: [Target]?
    let platforms: [Platform]?
}

private struct PackageGraph {
    let root: PackageDump
    let packages: [String: PackageDump]
    let packagesByProductName: [String: String]

    func product(name productName: String) throws -> (PackageDump, PackageDump.Product) {
        guard let packageID = packagesByProductName[productName] else {
            throw StringError("Could not find package containing product '\(productName)'")
        }
        guard let package = packages[packageID] else {
            throw StringError("Could not find package by id '\(packageID)'")
        }
        guard let product = package.products?.first(where: { $0.name == productName }) else {
            throw StringError("Could not find product '\(productName)' in package '\(packageID)'")
        }
        return (package, product)
    }
}
