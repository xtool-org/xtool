import Foundation

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

    public func createPlan() async throws -> Plan {
        // TODO: cache plan using (Package.swift+Package.resolved) as the key?
        let rootPackage = try await RootPackage(buildSettings: buildSettings)

        let app = try Plan.Product(
            from: rootPackage,
            matching: schema.product,
            type: .application,
            plist: schema.infoPath,
            idSpecifier: schema.idSpecifier,
            iconPath: schema.iconPath,
            rootResources: schema.resources,
            entitlementsPath: schema.entitlementsPath
        )

        let extensions = try (schema.extensions ?? []).map {
            try Plan.Product(
                from: rootPackage,
                matching: $0.product,
                type: .appExtension,
                plist: $0.infoPath,
                idSpecifier: $0.bundleID.flatMap(PackSchema.IDSpecifier.bundleID) ?? .orgID(app.bundleID),
                iconPath: nil,
                rootResources: $0.resources,
                entitlementsPath: $0.entitlementsPath
            )
        }

        return Plan(app: app, extensions: extensions)
    }
}

public struct Plan: Sendable {
    public var app: Product
    public var extensions: [Product]

    public var allProducts: [Product] {
        [app] + extensions
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
                case .application: baseDir
                    .appending(component: ".", directoryHint: .isDirectory)
                case .appExtension: baseDir
                    .appending(components: "Plugins", product, directoryHint: .isDirectory)
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

private extension Plan.Product {
    // swiftlint:disable function_parameter_count cyclomatic_complexity
    init(
        from rootPackage: RootPackage,
        matching name: String?,
        type: Plan.ProductType,
        plist: String?,
        idSpecifier: PackSchema.IDSpecifier,
        iconPath: String?,
        rootResources: [String]?,
        entitlementsPath: String?
    ) throws {
        let library = try Self.selectLibrary(
            from: rootPackage.products?.filter { $0.type == .autoLibrary } ?? [],
            matching: name
        )
        var resources: [Plan.Resource] = []
        var visited: Set<String> = []
        var targets = library.targets.map { (rootPackage.base, $0) }
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
                let (package, product) = try rootPackage.product(name: productName)
                if product.type == .dynamicLibrary {
                    resources.append(.library(name: productName))
                }
                targets.append(contentsOf: product.targets.map { (package, $0) })
            }
        }

        if let rootResources {
            resources += rootResources.compactMap(Plan.Resource.root)
        }

        let bundleID = idSpecifier.formBundleID(product: library.name)
        let deploymentTarget = rootPackage.platforms?.first { $0.name == "ios" }?.version ?? "13.0"

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
            infoPlist["UIRequiredDeviceCapabilities"] = ["arm64"]
            infoPlist["LSRequiresIPhoneOS"] = true
            infoPlist["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
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
            let data = try Data(contentsOf: URL(fileURLWithPath: plist))
            let info = try PropertyListSerialization.propertyList(from: data, format: nil)
            if let info = info as? [String: Sendable] {
                infoPlist.merge(info, uniquingKeysWith: { $1 })
            } else {
                throw StringError("Info.plist has invalid format: expected a dictionary.")
            }
        }

        self.init(
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

    private static func selectLibrary(
        from products: [PackageDump.Product],
        matching name: String?
    ) throws -> PackageDump.Product {
        switch products.count {
        case 0:
            throw StringError("No library products were found in the package")
        case 1:
            let product = products[0]
            if let name, product.name != name {
                throw StringError(
                    """
                    Product name ('\(product.name)') does not match the 'product' value in the schema ('\(name)')
                    """)
            }
            return product
        default:
            guard let name else {
                throw StringError(
                    """
                    Multiple library products were found (\(products.map(\.name))). Please either:
                    1) Expose exactly one library product, or
                    2) Specify the product you want via the 'product' key in xtool.yml.
                    """)
            }
            guard let product = products.first(where: { $0.name == name }) else {
                throw StringError(
                    """
                    Schema declares a 'product' name of '\(name)' but no matching product was found.
                    Found: \(products.map(\.name)).
                    """)
            }
            return product
        }
    }
}

private struct PackageDependency: Decodable {
    let identity: String
    let name: String
    let path: String  // on disk
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
        let productDependencies: [String]?
        let targetDependencies: [String]?
        let resources: [Resource]?
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

@dynamicMemberLookup
private struct RootPackage {
    let base: PackageDump
    let packages: [String: PackageDump]
    let packagesByProductName: [String: String]

    init(buildSettings: BuildSettings) async throws {
        let dependencyRoot = try await buildSettings.dumpDependencies()

        self.packages = try await withThrowingTaskGroup(
            of: (PackageDependency, PackageDump).self,
            returning: [String: PackageDump].self
        ) { group in
            var visited: Set<String> = []
            var dependencies: [PackageDependency] = [dependencyRoot]
            while let dependencyNode = dependencies.popLast() {
                guard visited.insert(dependencyNode.identity).inserted else { continue }
                dependencies.append(contentsOf: dependencyNode.dependencies)
                group.addTask { (dependencyNode, try await buildSettings.dumpPackage(at: dependencyNode.path)) }
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

        self.base = packages[dependencyRoot.identity]!
        self.packagesByProductName = packages.reduce(into: [:]) { result, pair in
            for product in pair.value.products ?? [] {
                result[product.name] = pair.key
            }
        }
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<PackageDump, Value>) -> Value {
        self.base[keyPath: keyPath]
    }

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

private extension BuildSettings {
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func dumpDependencies(path: String? = nil) async throws -> PackageDependency {
        let tempFileName = "xtool." + UUID().uuidString.replacing("-", with: "").lowercased()
        let tempFileURL = FileManager.default.temporaryDirectory.appending(path:  tempFileName, directoryHint: .notDirectory)
        try? FileManager.default.createDirectory(at: tempFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFileURL) }

        // some verbose is included in stdout. we should ignore it and use "-o" to get the raw dump.
        // This is better than finding the opening curly braces character "{"
        _ = try await self._dumpAction(
            arguments: ["-q", "show-dependencies", "--format", "json", "-o", tempFileURL.path(percentEncoded: false)],
            path: path ?? self.packagePath
        )

        return try Self.decoder.decode(
            PackageDependency.self,
            from: Data(contentsOf: tempFileURL)
        )
    }

    func dumpPackage(at path: String) async throws -> PackageDump {
        let data = try await _dumpAction(arguments: ["-q", "describe", "--type", "json"], path: path)
        try Task.checkCancellation()

        // See if SwiftPM allows exporting to a file without verbose/etc
        if let openingBracesIdx = data.firstIndex(where: { $0 == Character("{").asciiValue }) {
            return try Self.decoder.decode(PackageDump.self, from: data[openingBracesIdx...])
        } else {
            return try Self.decoder.decode(PackageDump.self, from: data)
        }
    }

    private func _dumpAction(arguments: [String], path: String) async throws -> Data {
        let dump = try await self.swiftPMInvocation(
            forTool: "package",
            arguments: arguments,
            packagePathOverride: path
        )
        let pipe = Pipe()
        dump.standardOutput = pipe
        async let task = Data(reading: pipe.fileHandleForReading)
        try await dump.runUntilExit()
        return try await task
    }
}