import Foundation
import Yams
import XUtils

public struct PackSchemaBase: Codable, Sendable {
    public enum Version: Int, Codable, Sendable {
        case v1 = 1
        case v2 = 2
    }

    public var version: Version

    public var orgID: String?
    public var bundleID: String?

    public var product: String?

    /// Version 2 only. Omission retains the legacy arm64 iOS target.
    public var target: String?
    public var deploymentTarget: String?
    public var source: ProductSource?
    public var resourceCopies: [ResourceCopy]?
    public var nestedProducts: [NestedProduct]?

    public var infoPath: String?
    public var entitlementsPath: String?

    public var iconPath: String?
    public var resources: [String]?

    public var extensions: [Extension]?

    /// Skip auto-creating the LSP support file if it's missing.
    public var skipLSP: Bool?

    public struct Extension: Codable, Sendable {
        public var product: String
        public var bundleID: String?
        public var infoPath: String
        public var resources: [String]?
        public var entitlementsPath: String?
        public var source: ProductSource?
        public var resourceCopies: [ResourceCopy]?
    }

    public struct NestedProduct: Codable, Sendable {
        public var product: String
        public var kind: Plan.ProductType
        public var source: ProductSource
        public var bundleID: String?
        public var infoPath: String?
        public var entitlementsPath: String?
        public var resourceCopies: [ResourceCopy]?
    }
}

@dynamicMemberLookup
public struct PackSchema: Sendable {
    public typealias Extension = PackSchemaBase.Extension

    public enum IDSpecifier: Sendable {
        case orgID(String)
        case bundleID(String)

        func formBundleID(product: String) -> String {
            switch self {
            case .orgID(let orgID): "\(orgID).\(product)"
            case .bundleID(let bundleID): bundleID
            }
        }
    }

    public let base: PackSchemaBase
    public let idSpecifier: IDSpecifier

    public init(validating base: PackSchemaBase) throws {
        self.base = base

        try Self.validateConfiguration(base)

        switch (base.bundleID, base.orgID) {
        case (let bundleID?, _):
            idSpecifier = .bundleID(bundleID)
        case (nil, let orgID?):
            idSpecifier = .orgID(orgID)
        case (nil, nil):
            throw StringError("xtool.yml: Must specify either orgID or bundleID")
        }

        if let iconPath = base.iconPath {
            let ext = URL(fileURLWithPath: iconPath).pathExtension
            let allowed = base.version == .v1 ? ["png"] : ["png", "icns"]
            guard allowed.contains(ext) else {
                throw StringError("xtool.yml: iconPath must be a prepared \(allowed.joined(separator: " or ")) file. Got '\(ext)'.")
            }
        }
    }

    private static func validateConfiguration(_ base: PackSchemaBase) throws {
        if base.version == .v1 {
            guard base.target == nil, base.deploymentTarget == nil, base.source == nil,
                  base.resourceCopies == nil, base.nestedProducts == nil,
                  !(base.extensions ?? []).contains(where: { $0.source != nil || $0.resourceCopies != nil }) else {
                throw StringError("xtool.yml: target, deploymentTarget, source, resourceCopies and nestedProducts require version: 2")
            }
        }
        if let target = base.target { _ = try TargetTriple(target) }
        if let deployment = base.deploymentTarget { try TargetTriple.validateVersion(deployment) }
        try base.source?.validate()
        try validateProducts(base)
    }

    private static func validateProducts(_ base: PackSchemaBase) throws {
        for product in base.nestedProducts ?? [] {
            try Self.validateName(product.product)
            guard product.kind != .application else {
                throw StringError("xtool.yml: nestedProducts cannot contain an application")
            }
            try product.source.validate()
            if product.kind == .appExtension || product.kind == .xpcService {
                guard product.infoPath != nil else {
                    throw StringError("xtool.yml: nested extensions and XPC services require infoPath")
                }
            }
        }
        let copies = (base.resourceCopies ?? []) + (base.extensions ?? []).flatMap { $0.resourceCopies ?? [] }
            + (base.nestedProducts ?? []).flatMap { $0.resourceCopies ?? [] }
        for copy in copies {
            guard !copy.source.isEmpty else { throw StringError("xtool.yml: resource source cannot be empty") }
            try copy.destination.validate()
        }
        if let product = base.product { try Self.validateName(product) }
        for ext in base.extensions ?? [] {
            try Self.validateName(ext.product)
            try ext.source?.validate()
        }
        let names = (base.extensions ?? []).map(\.product) + (base.nestedProducts ?? []).map(\.product)
        guard Set(names).count == names.count else {
            throw StringError("xtool.yml: nested product names must be unique")
        }
    }

    private static func validateName(_ name: String) throws {
        try ResourceDestination.validateComponent(name, "xtool.yml: product name")
    }

    /// Validate against the effective CLI/schema target, after precedence is applied.
    public func validate(for platform: TargetPlatform) throws {
        if platform != .macOS {
            guard !(base.nestedProducts ?? []).contains(where: { $0.kind == .xpcService || $0.kind == .helperExecutable }) else {
                throw StringError("xtool.yml: XPC services and helper executables require a macOS target")
            }
            if let iconPath = base.iconPath, URL(fileURLWithPath: iconPath).pathExtension == "icns" {
                throw StringError("xtool.yml: icns icons require a macOS target")
            }
        }
    }

    // swiftlint:disable:next force_try
    public static let `default` = try! PackSchema(validating: .init(
        version: .v1,
        orgID: "com.example"
    ))

    public init(url: URL) async throws {
        let data = try await Data(reading: url)
        let base = try YAMLDecoder().decode(PackSchemaBase.self, from: data)
        try self.init(validating: base)
    }

    public subscript<Subject>(dynamicMember keyPath: KeyPath<PackSchemaBase, Subject>) -> Subject {
        self.base[keyPath: keyPath]
    }
}
