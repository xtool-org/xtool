//
//  DeveloperServicesListAppIDsRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesListAppIDsRequest: DeveloperServicesPlatformRequest {

    public struct Response: Decodable, Sendable {
        public let appIds: [DeveloperServicesAppID]
    }
    public typealias Value = [DeveloperServicesAppID]

    public let platform: DeveloperServicesPlatform
    public let teamID: DeveloperServicesTeam.ID

    var subAction: String { return "listAppIds" }
    var subParameters: [String: Any] {
        return ["teamId": teamID.rawValue]
    }

    public func parse(_ response: Response) -> [DeveloperServicesAppID] {
        response.appIds
    }

    public init(platform: DeveloperServicesPlatform, teamID: DeveloperServicesTeam.ID) {
        self.platform = platform
        self.teamID = teamID
    }

}
