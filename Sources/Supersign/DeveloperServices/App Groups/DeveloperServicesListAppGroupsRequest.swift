//
//  DeveloperServicesListAppGroupsRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesListAppGroupsRequest: DeveloperServicesPlatformRequest {

    public struct Response: Decodable, Sendable {
        public let applicationGroupList: [DeveloperServicesAppGroup]
    }
    public typealias Value = [DeveloperServicesAppGroup]

    public let platform: DeveloperServicesPlatform
    public let teamID: DeveloperServicesTeam.ID

    var subAction: String { return "listApplicationGroups" }
    var subParameters: [String: Any] {
        return ["teamId": teamID.rawValue]
    }

    public func parse(_ response: Response) -> [DeveloperServicesAppGroup] {
        response.applicationGroupList
    }

    public init(platform: DeveloperServicesPlatform, teamID: DeveloperServicesTeam.ID) {
        self.platform = platform
        self.teamID = teamID
    }

}
