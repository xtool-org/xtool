//
//  DeveloperServicesAddAppGroupRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesAddAppGroupRequest: DeveloperServicesPlatformRequest {

    public struct Response: Decodable, Sendable {
        let applicationGroup: DeveloperServicesAppGroup
    }
    public typealias Value = DeveloperServicesAppGroup

    public let platform: DeveloperServicesPlatform
    public let teamID: DeveloperServicesTeam.ID
    public let name: String
    public let groupID: DeveloperServicesAppGroup.GroupID

    var subAction: String { return "addApplicationGroup" }
    var subParameters: [String: Any] {
        return [
            "teamId": teamID.rawValue,
            "name": name,
            "identifier": groupID.rawValue
        ]
    }

    public func parse(_ response: Response) -> DeveloperServicesAppGroup {
        response.applicationGroup
        //abc
    }

    public init(
        platform: DeveloperServicesPlatform,
        teamID: DeveloperServicesTeam.ID,
        name: String,
        groupID: DeveloperServicesAppGroup.GroupID
    ) {
        self.platform = platform
        self.teamID = teamID
        self.name = name
        self.groupID = groupID
    }

}
