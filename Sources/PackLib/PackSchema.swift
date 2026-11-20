import Foundation
import Yams
import XUtils

public struct PackSchemaBase: Codable, Sendable {
    fileprivate enum CodingKeys: String, CodingKey {
        case version, orgID, bundleID, product, infoPath, entitlementsPath, iconPath, resources, extensions, skipLSP
    }

    public enum Version: Int, Codable, Sendable {
        case v1 = 1
    }

    public var version: Version

    public var orgID: String?
    public var bundleID: String?

    public var product: String?

    public var infoPath: String?
    public var entitlementsPath: String?

    public var iconPath: String?
    public var resources: [String]?

    public var extensions: [Extension]?

    /// Skip auto-creating the LSP support file if it's missing.
    public var skipLSP: Bool?

    public struct Extension: Codable, Sendable {
        fileprivate enum CodingKeys: String, CodingKey {
            case product, bundleID, infoPath, resources, entitlementsPath
        }

        public var product: String
        public var bundleID: String?
        public var infoPath: String
        public var resources: [String]?
        public var entitlementsPath: String?
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

        if base.version != .v1 {
            throw StringError("xtool.yml: Unsupported schema version: \(base.version.rawValue)")
        }

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
            guard ext == "png" else {
                throw StringError("xtool.yml: iconPath should have a 'png' path extension. Got '\(ext)'.")
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
        let config: PackConfigFile
        do {
            config = try YAMLDecoder().decode(PackConfigFile.self, from: data)
        } catch DecodingError.dataCorrupted(let context) {
            // Yams wraps validation errors in a generic invalid-YAML error.
            if let error = context.underlyingError as? StringError {
                throw error
            }
            throw DecodingError.dataCorrupted(context)
        }
        try self.init(validating: config.base)
    }

    public subscript<Subject>(dynamicMember keyPath: KeyPath<PackSchemaBase, Subject>) -> Subject {
        self.base[keyPath: keyPath]
    }
}

private struct PackConfigFile: Decodable {
    let base: PackSchemaBase

    init(from decoder: any Decoder) throws {
        try Self.checkKeys(PackSchemaBase.CodingKeys.self, in: decoder)
        let container = try decoder.container(keyedBy: PackSchemaBase.CodingKeys.self)
        _ = try container.decodeIfPresent([ExtensionKeyCheck].self, forKey: .extensions)
        base = try PackSchemaBase(from: decoder)
    }

    private struct ExtensionKeyCheck: Decodable {
        init(from decoder: any Decoder) throws {
            let index = decoder.codingPath.last?.intValue
            let location = index.map { " in extensions[\($0)]" } ?? " in extensions"
            try PackConfigFile.checkKeys(PackSchemaBase.Extension.CodingKeys.self, in: decoder, location: location)
        }
    }

    private struct RawKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func checkKeys<Key: CodingKey>(
        _ keyType: Key.Type,
        in decoder: any Decoder,
        location: String = ""
    ) throws {
        let container = try decoder.container(keyedBy: RawKey.self)
        let unknownKeys = Set(container.allKeys.map(\.stringValue))
            .filter { Key(stringValue: $0) == nil }
            .sorted()
        guard !unknownKeys.isEmpty else { return }

        let label = unknownKeys.count == 1 ? "key" : "keys"
        let names = unknownKeys.map { String(reflecting: $0) }.joined(separator: ", ")
        throw StringError("xtool.yml: Unknown \(label)\(location): \(names).")
    }
}
