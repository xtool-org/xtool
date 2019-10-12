//
//  DeveloperServicesDeleteProfileRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesDeleteProfileRequest: DeveloperServicesPlatformRequest {

    public struct Response: Decodable {}
    public typealias Value = Response

    public let platform: DeveloperServicesPlatform
    public let teamID: DeveloperServicesTeam.ID
    public let profileID: DeveloperServicesProfile.ID

    var subAction: String { return "deleteProvisioningProfile" }
    var subParameters: [String: Any] {
        return ["teamId": teamID.rawValue, "provisioningProfileId": profileID.rawValue]
    }

    public init(
        platform: DeveloperServicesPlatform,
        teamID: DeveloperServicesTeam.ID,
        profileID: DeveloperServicesProfile.ID
    ) {
        self.platform = platform
        self.teamID = teamID
        self.profileID = profileID
    }

}
