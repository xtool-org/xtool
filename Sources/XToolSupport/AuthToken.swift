import Foundation
import XKit
import Dependencies

enum AuthToken: Codable, CustomStringConvertible {
    struct Xcode: Codable {
        var appleID: String
        var adsid: String
        var token: String
        var expiry: Date
        var teamID: String
    }

    struct AppStoreConnect: Codable {
        var id: String
        var issuerID: String
        var pem: String
    }

    case appStoreConnect(AppStoreConnect)
    case xcode(Xcode)

    var description: String {
        switch self {
        case .appStoreConnect(let data):
            """
            - ASC key ID: \(data.id)
            - Issuer ID: \(data.issuerID)
            """
        case .xcode(let data):
            """
            - Apple ID: \(data.appleID)
            - Team ID: \(data.teamID)
            - Token expiry: \(data.expiry.formatted(.dateTime))
            """
        }
    }
}

extension AuthToken {

    private static var storage: KeyValueStorage {
        @Dependency(\.keyValueStorage) var storage
        return storage
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func saved() throws -> Self {
        guard let data = try storage.data(forKey: "XTLAuthToken") else {
            throw Console.Error("Please log in with `xtool auth` before running this command.")
        }
        return try decoder.decode(AuthToken.self, from: data)
    }

    static func clear() throws {
        try Self.storage.setData(nil, forKey: "XTLAuthToken")
    }

    func save() throws {
        let data = try Self.encoder.encode(self)
        try Self.storage.setData(data, forKey: "XTLAuthToken")
    }

    func authData() throws -> DeveloperAPIAuthData {
        switch self {
        case .appStoreConnect(let data):
            return .appStoreConnect(.init(id: data.id, issuerID: data.issuerID, pem: data.pem))
        case .xcode(let data):
            return .xcode(.init(
                loginToken: DeveloperServicesLoginToken(
                    adsid: data.adsid,
                    token: data.token,
                    expiry: data.expiry
                ),
                teamID: .init(rawValue: data.teamID)
            ))
        }
    }

}
