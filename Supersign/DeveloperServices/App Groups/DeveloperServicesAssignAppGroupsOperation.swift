//
//  DeveloperServicesAssignAppGroupsOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 14/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesAssignAppGroupsOperation: DeveloperServicesOperation {

    public let context: SigningContext
    public let groupIDs: [DeveloperServicesAppGroup.GroupID]
    public let appID: DeveloperServicesAppID
    public init(context: SigningContext, groupIDs: [DeveloperServicesAppGroup.GroupID], appID: DeveloperServicesAppID) {
        self.context = context
        self.groupIDs = groupIDs
        self.appID = appID
    }

    private func assignAppGroup(
        _ group: DeveloperServicesAppGroup,
        appID: DeveloperServicesAppID,
        completion: @escaping (Result<DeveloperServicesAppGroup.GroupID, Swift.Error>) -> Void
    ) {
        let request = DeveloperServicesAssignAppGroupRequest(
            platform: context.platform, teamID: context.teamID, appIDID: appID.id, groupID: group.id
        )
        context.client.send(request) { result in
            guard result.get(withErrorHandler: completion) != nil else { return }
            completion(.success(group.groupID))
        }
    }

    private func addOrAssignAppGroup(
        _ groupID: DeveloperServicesAppGroup.GroupID,
        existingGroups: [DeveloperServicesAppGroup],
        appID: DeveloperServicesAppID,
        completion: @escaping (Result<DeveloperServicesAppGroup.GroupID, Swift.Error>) -> Void
    ) {
        let sanitized = ProvisioningIdentifiers.sanitize(groupID: groupID)
        if let group = existingGroups.first(where: {
            ProvisioningIdentifiers.sanitize(groupID: $0.groupID) == sanitized
        }) {
            assignAppGroup(group, appID: appID, completion: completion)
        } else {
            let groupID = ProvisioningIdentifiers.groupID(fromSanitized: sanitized)
            let name = ProvisioningIdentifiers.groupName(fromSanitized: sanitized)
            let request = DeveloperServicesAddAppGroupRequest(
                platform: context.platform, teamID: context.teamID, name: name, groupID: groupID
            )
            context.client.send(request) { result in
                guard let group = result.get(withErrorHandler: completion) else { return }
                self.assignAppGroup(group, appID: appID, completion: completion)
            }
        }
    }

    public func perform(completion: @escaping (Result<[DeveloperServicesAppGroup.GroupID], Error>) -> Void) {
        let request = DeveloperServicesListAppGroupsRequest(platform: context.platform, teamID: context.teamID)
        context.client.send(request) { result in
            guard let existingGroups = result.get(withErrorHandler: completion) else { return }

            let grouper = RequestGrouper<DeveloperServicesAppGroup.GroupID, Error>()
            for groupID in self.groupIDs {
                grouper.add { completion in
                    self.addOrAssignAppGroup(
                        groupID, existingGroups: existingGroups, appID: self.appID, completion: completion
                    )
                }
            }
            grouper.onComplete(completion)
        }
    }

}
