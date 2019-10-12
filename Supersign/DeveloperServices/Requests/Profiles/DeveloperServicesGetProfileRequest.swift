//
//  DeveloperServicesGetProfileRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesGetProfileRequest: DeveloperServicesPlatformRequest {

    public struct Response: Decodable {
        public let provisioningProfile: DeveloperServicesProfile
    }
    public typealias Value = DeveloperServicesProfile

    public let platform: DeveloperServicesPlatform
    public let teamID: DeveloperServicesTeam.ID
    public let appIDID: DeveloperServicesAppID.ID

    var subAction: String { return "downloadTeamProvisioningProfile" }
    var subParameters: [String: Any] {
        return ["teamId": teamID.rawValue, "appIdId": appIDID.rawValue]
    }

    public func parse(_ response: Response, completion: @escaping (Result<Value, Error>) -> Void) {
        completion(.success(response.provisioningProfile))
    }

    public init(
        platform: DeveloperServicesPlatform,
        teamID: DeveloperServicesTeam.ID,
        appIDID: DeveloperServicesAppID.ID
    ) {
        self.platform = platform
        self.teamID = teamID
        self.appIDID = appIDID
    }

}
