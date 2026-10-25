//
//  DeveloperServicesAssignAppGroupRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

/// Assigns a set of app groups to an App ID. The request replaces the App ID's groups with
/// `groupIDs`, so every group the app needs has to be in one request: assigning them one
/// request at a time leaves only the last one standing.
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
