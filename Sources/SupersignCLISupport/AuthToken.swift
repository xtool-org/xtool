import Foundation
import Supersign

struct AuthToken: Codable {
    var appleID: String
    var adsid: String
    var token: String
    var expiry: Date

    private var _teamID: String
    var teamID: DeveloperServicesTeam.ID {
        get { .init(rawValue: _teamID) }
        set { _teamID = newValue.rawValue }
    }

    private enum CodingKeys: String, CodingKey {
        case appleID
        case _teamID = "teamID"
        case adsid
        case token
        case expiry
    }
}

extension AuthToken {

    init(
        appleID: String,
        teamID: DeveloperServicesTeam.ID,
        dsToken: DeveloperServicesLoginToken
    ) {
        self.appleID = appleID
        self._teamID = teamID.rawValue
        self.adsid = dsToken.adsid
        self.token = dsToken.token
        self.expiry = dsToken.expiry
    }

    var dsToken: DeveloperServicesLoginToken {
        DeveloperServicesLoginToken(
            adsid: adsid,
            token: token,
            expiry: expiry
        )
    }

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

}
