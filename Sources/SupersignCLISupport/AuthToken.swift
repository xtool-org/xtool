import Foundation
import Supersign

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

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func saved() throws -> Self {
        guard let data = try SupersignCLI.config.storage.data(forKey: "SUPAuthToken") else {
            throw Console.Error("Please log in with `supersign ds login` before running this command.")
        }
        return try decoder.decode(AuthToken.self, from: data)
    }

    static func clear() throws {
        try SupersignCLI.config.storage.setData(nil, forKey: "SUPAuthToken")
    }

    func save() throws {
        let data = try Self.encoder.encode(self)
        try SupersignCLI.config.storage.setData(data, forKey: "SUPAuthToken")
    }

    func authData() throws -> DeveloperAPIAuthData {
        switch self {
        case .appStoreConnect(let data):
            return .appStoreConnect(.init(id: data.id, issuerID: data.issuerID, pem: data.pem))
        case .xcode(let data):
            let deviceInfo = try DeviceInfo.fetch()
            return .xcode(.init(
                loginToken: DeveloperServicesLoginToken(
                    adsid: data.adsid,
                    token: data.token,
                    expiry: data.expiry
                ),
                deviceInfo: deviceInfo,
                teamID: .init(rawValue: data.teamID),
                anisetteDataProvider: try ADIDataProvider.adiProvider(
                    deviceInfo: deviceInfo,
                    storage: SupersignCLI.config.storage
                )
            ))
        }
    }

}
