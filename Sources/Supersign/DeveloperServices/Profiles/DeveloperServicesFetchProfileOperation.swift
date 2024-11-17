//
//  DeveloperServicesFetchProfileOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import Superutils

public struct DeveloperServicesFetchProfileOperation: DeveloperServicesOperation {

    public let context: SigningContext
    public let appID: DeveloperServicesAppID
    public init(context: SigningContext, appID: DeveloperServicesAppID) {
        self.context = context
        self.appID = appID
    }

    public func perform() async throws -> DeveloperServicesProfile {
        let profiles = try await context.client.send(DeveloperServicesListProfilesRequest(
            platform: context.platform, teamID: context.teamID
        ))
        if let profile = profiles.first(where: { $0.appID.id == self.appID.id }) {
            _ = try await context.client.send(DeveloperServicesDeleteProfileRequest(
                platform: context.platform, teamID: context.teamID, profileID: profile.id
            ))
        }
        return try await context.client.send(DeveloperServicesGetProfileRequest(
            platform: context.platform, teamID: context.teamID, appIDID: appID.id
        ))
    }

}
