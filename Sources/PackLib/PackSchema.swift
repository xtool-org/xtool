import Foundation
import Yams

public struct PackSchemaBase: Codable, Sendable {
    public enum Version: Int, Codable, Sendable {
        case v1 = 1
    }

    public var version: Version

    public var orgID: String?
    public var bundleID: String?

    public var product: String?

    public var infoPath: String?
}

public struct PackSchema: Sendable {
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
            throw StringError("supersign.yml: Unsupported schema version: \(base.version.rawValue)")
        }

        switch (base.bundleID, base.orgID) {
        case (let bundleID?, _):
            idSpecifier = .bundleID(bundleID)
        case (nil, let orgID?):
            idSpecifier = .orgID(orgID)
        case (nil, nil):
            throw StringError("supersign.yml: Must specify either orgID or bundleID")
        }
    }

    public static let `default` = try! PackSchema(validating: .init(
        version: .v1,
        orgID: "com.example"
    ))

    public init(url: URL) async throws {
        let data = try await Data(reading: url)
        let base = try YAMLDecoder().decode(PackSchemaBase.self, from: data)
        try self.init(validating: base)
    }
}
