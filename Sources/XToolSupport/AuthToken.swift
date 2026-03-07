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
    static let signingP12PathKey = "XTLSavedSigningP12Path"
    static let signingP12PasswordKey = "XTLSavedSigningP12Password"

    static func saved() throws -> Self {
        guard let data = try storage.data(forKey: "XTLAuthToken") else {
            throw Console.Error("Please log in with `xtool auth` before running this command.")
        }
        return try decoder.decode(AuthToken.self, from: data)
    }

    static func clear() throws {
        try Self.storage.setData(nil, forKey: "XTLAuthToken")
        try clearSigningCertificate()
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

    static func saveSigningCertificate(path: String, password: String) throws {
        try storage.setString(path, forKey: Self.signingP12PathKey)
        try storage.setString(password, forKey: Self.signingP12PasswordKey)
    }

    static func savedSigningCertificatePath() throws -> String? {
        try storage.string(forKey: Self.signingP12PathKey)
    }

    static func savedSigningCertificatePassword() throws -> String? {
        try storage.string(forKey: Self.signingP12PasswordKey)
    }

    static func clearSigningCertificate() throws {
        if let path = try savedSigningCertificatePath() {
            try? FileManager.default.removeItem(atPath: path)
        }
        try storage.setData(nil, forKey: Self.signingP12PathKey)
        try storage.setData(nil, forKey: Self.signingP12PasswordKey)
    }

}
