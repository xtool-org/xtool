//
//  DeveloperServicesAssignAppGroupRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

/// Replaces all of the app's groups with the given ones
public final class DeveloperServicesAssignAppGroupRequest: DeveloperServicesPlatformRequest {

    public struct Response: Decodable, Sendable {}
    public typealias Value = Response

    public let platform: DeveloperServicesPlatform
    public let teamID: DeveloperServicesTeam.ID
    public let appIDID: String
    public let groupIDs: [DeveloperServicesAppGroup.ID]

    var subAction: String { return "assignApplicationGroupToAppId" }
    var subParameters: [String: Any] {
        return [
            "teamId": teamID.rawValue,
            "appIdId": appIDID,
            "applicationGroups": groupIDs.map(\.rawValue)
        ]
    }

    public init(
        platform: DeveloperServicesPlatform,
        teamID: DeveloperServicesTeam.ID,
        appIDID: String,
        groupIDs: [DeveloperServicesAppGroup.ID]
    ) {
        self.platform = platform
        self.teamID = teamID
        self.appIDID = appIDID
        self.groupIDs = groupIDs
    }

}
