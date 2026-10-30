//
//  DeveloperServicesAssignAppGroupsOperation.swift
//  XKit
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

    private func getOrCreateAppGroup(
        _ groupID: DeveloperServicesAppGroup.GroupID,
        existingGroups: [String: DeveloperServicesAppGroup]
    ) async throws -> DeveloperServicesAppGroup {
        let sanitized = ProvisioningIdentifiers.sanitize(groupID: groupID)
        if let existingGroup = existingGroups[sanitized] {
            return existingGroup
        }
        let groupID = ProvisioningIdentifiers.groupID(fromSanitized: sanitized, context: context)
        let name = ProvisioningIdentifiers.groupName(fromSanitized: sanitized)
        let request = DeveloperServicesAddAppGroupRequest(
            platform: .iOS,
            teamID: xcodeAuthData.teamID,
            name: name,
            groupID: groupID
        )
        return try await client.send(request)
    }

    public func perform() async throws -> [DeveloperServicesAppGroup.GroupID] {
        let existing = try await client.send(DeveloperServicesListAppGroupsRequest(
            platform: .iOS, teamID: xcodeAuthData.teamID
        ))
        let sanitized = existing.map { (ProvisioningIdentifiers.sanitize(groupID: $0.groupID), $0) }
        let dict = Dictionary(sanitized, uniquingKeysWith: { $1 })
        let groups = try await withThrowingTaskGroup(of: (Int, DeveloperServicesAppGroup).self) { group in
            for (index, groupID) in groupIDs.enumerated() {
                group.addTask {
                    (index, try await getOrCreateAppGroup(groupID, existingGroups: dict))
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)

        _ = try await client.send(
            DeveloperServicesAssignAppGroupRequest(
                platform: .iOS,
                teamID: xcodeAuthData.teamID,
                appIDID: appID.id,
                groupIDs: groups.map(\.id)
            )
        )

        return groups.map(\.groupID)
    }

}
