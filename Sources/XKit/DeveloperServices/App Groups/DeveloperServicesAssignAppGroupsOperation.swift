//
//  DeveloperServicesAssignAppGroupsOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 14/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import DeveloperAPI

public struct DeveloperServicesAssignAppGroupsOperation: DeveloperServicesOperation {

    public let context: SigningContext
    public let groupIDs: [DeveloperServicesAppGroup.GroupID]
    public let appID: Components.Schemas.BundleId
    public let xcodeAuthData: XcodeAuthData

    private let client: DeveloperServicesClient

    public init?(
        context: SigningContext,
        groupIDs: [DeveloperServicesAppGroup.GroupID],
        appID: Components.Schemas.BundleId
    ) {
        self.context = context
        self.groupIDs = groupIDs
        self.appID = appID

        guard case .xcode(let authData) = context.auth else { return nil }
        self.xcodeAuthData = authData

        self.client = DeveloperServicesClient(authData: authData)
    }

    private func upsertAppGroup(
        _ groupID: DeveloperServicesAppGroup.GroupID,
        existingGroups: [String: DeveloperServicesAppGroup]
    ) async throws -> DeveloperServicesAppGroup.GroupID {
        let sanitized = ProvisioningIdentifiers.sanitize(groupID: groupID)
        let group: DeveloperServicesAppGroup
        if let existingGroup = existingGroups[sanitized] {
            group = existingGroup
        } else {
            let groupID = ProvisioningIdentifiers.groupID(fromSanitized: sanitized, context: context)
            let name = ProvisioningIdentifiers.groupName(fromSanitized: sanitized)
            let request = DeveloperServicesAddAppGroupRequest(
                platform: .iOS,
                teamID: xcodeAuthData.teamID,
                name: name,
                groupID: groupID
            )
            group = try await client.send(request)
        }

        _ = try await client.send(
            DeveloperServicesAssignAppGroupRequest(
                platform: .iOS,
                teamID: xcodeAuthData.teamID,
                appIDID: appID.id,
                groupID: group.id
            )
        )

        return group.groupID
    }

    public func perform() async throws -> [DeveloperServicesAppGroup.GroupID] {
        let existing = try await client.send(DeveloperServicesListAppGroupsRequest(
            platform: .iOS, teamID: xcodeAuthData.teamID
        ))
        let sanitized = existing.map { (ProvisioningIdentifiers.sanitize(groupID: $0.groupID), $0) }
        let dict = Dictionary(sanitized, uniquingKeysWith: { $1 })
        return try await withThrowingTaskGroup(of: DeveloperServicesAppGroup.GroupID.self) { group in
            for groupID in groupIDs {
                group.addTask {
                    try await upsertAppGroup(groupID, existingGroups: dict)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    }

}
