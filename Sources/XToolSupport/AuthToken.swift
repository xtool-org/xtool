import XCLIUtils
import XUtils
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
        var anisetteProviderID: String?
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
        let (token, anisetteProviderChanged) = try load()
        guard let token else {
            throw Console.Error(anisetteProviderChanged ? """
            You were logged out because xtool now generates Anisette data differently. \
            Please log in again with `xtool auth`.
            """ : "Please log in with `xtool auth` before running this command.")
        }
        return token
    }

    static func savedIfPresent() throws -> Self? {
        try load().token
    }

    private static func load() throws -> (token: Self?, anisetteProviderChanged: Bool) {
        guard let data = try storage.data(forKey: "XTLAuthToken") else {
            return (nil, false)
        }
        let decoded = try decoder.decode(AuthToken.self, from: data)
        switch decoded {
        case .xcode(let xcode):
            @Dependency(\.anisetteDataProvider) var anisetteProvider
            guard xcode.anisetteProviderID == anisetteProvider.providerID else {
                try? clear()
                return (nil, true)
            }
        case .appStoreConnect:
            break
        }
        return (decoded, false)
    }

    static func clear() throws {
        try Self.storage.setData(nil, forKey: "XTLAuthToken")
    }

    func save() throws {
        let data = try Self.encoder.encode(self)
        try Self.storage.setData(data, forKey: "XTLAuthToken")
    }

    func authData() -> DeveloperAPIAuthData {
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
