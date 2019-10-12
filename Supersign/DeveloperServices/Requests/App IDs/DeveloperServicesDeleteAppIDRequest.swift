//
//  DeveloperServicesDeleteAppIDRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesDeleteAppIDRequest: DeveloperServicesPlatformRequest {

    public struct Response: Decodable {}
    public typealias Value = Response

    public let platform: DeveloperServicesPlatform
    public let teamID: DeveloperServicesTeam.ID
    public let appIDID: DeveloperServicesAppID.ID

    var subAction: String { return "deleteAppId" }
    var subParameters: [String: Any] {
        return ["teamId": teamID.rawValue, "appIdId": appIDID.rawValue]
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
