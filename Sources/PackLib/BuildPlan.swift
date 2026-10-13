import Foundation
import XUtils

public struct Plan: Sendable {
    public let target: ResolvedTarget
    public var app: Product
    public var extensions: [Product]
    public var nestedProducts: [Product]

    public init(target: ResolvedTarget, app: Product, extensions: [Product] = [], nestedProducts: [Product] = []) throws {
        let products = [app] + extensions + nestedProducts
        guard products.allSatisfy({ $0.target == target }), app.type == .application,
              extensions.allSatisfy({ $0.type == .appExtension }),
              nestedProducts.allSatisfy({ $0.type != .application }),
              Set(products.map(\.product)).count == products.count else {
            throw StringError("Build plan has inconsistent targets, product kinds, or duplicate names")
        }
        self.target = target
        self.app = app
        self.extensions = extensions
        self.nestedProducts = nestedProducts
    }

    public var allProducts: [Product] {
        [app] + extensions + nestedProducts
    }

    public enum Resource: Codable, Sendable, Hashable {
        case bundle(package: String, target: String)
        case binaryTarget(name: String)
        case library(name: String)
        case root(source: String)
        case copy(ResourceCopy)
    }

    public struct Product: Sendable {
        public let target: ResolvedTarget
        public var platform: TargetPlatform { target.platform }
        public var source: ProductSource?
        public var type: ProductType
        public var product: String
        public var deploymentTarget: String { target.deploymentTarget }
        public var bundleID: String
        public var infoPlist: [String: any Sendable]
        public var resources: [Resource]
        public var iconPath: String?
        public var entitlementsPath: String?

        public var resolvedSource: ProductSource { source ?? .library(product: product) }

        public var layout: BundleLayout { .init(platform: platform, kind: type, name: product) }

        public var targetName: String {
            "\(self.product)-\(self.type.targetSuffix)"
        }

        public func directory(inApp baseDir: URL) -> URL {
            baseDir.appendingPathComponent(layout.bundlePath, isDirectory: type != .helperExecutable)
        }
    }

    public enum ProductType: String, Codable, Sendable, Equatable {
        case application
        case appExtension
        case xpcService
        case helperExecutable

        var targetSuffix: String {
            switch self {
            case .application: "App"
            case .appExtension: "Extension"
            case .xpcService: "XPCService"
            case .helperExecutable: "Helper"
            }
        }

        var fourCharCode: String {
            switch self {
            case .application: "APPL"
            case .appExtension, .xpcService: "XPC!"
            case .helperExecutable: ""
            }
        }
    }
}
