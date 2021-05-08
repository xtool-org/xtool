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

    private func createProfile(
        appID: DeveloperServicesAppID,
        completion: @escaping (Result<DeveloperServicesProfile, Swift.Error>) -> Void
    ) {
        let request = DeveloperServicesGetProfileRequest(
            platform: context.platform, teamID: context.teamID, appIDID: appID.id
        )
        context.client.send(request, completion: completion)
    }

    public func perform(completion: @escaping (Result<DeveloperServicesProfile, Error>) -> Void) {
        let request = DeveloperServicesListProfilesRequest(platform: context.platform, teamID: context.teamID)
        context.client.send(request) { result in
            guard let profiles = result.get(withErrorHandler: completion) else { return }
            if let profile = profiles.first(where: { $0.appID.id == self.appID.id }) {
                let request = DeveloperServicesDeleteProfileRequest(
                    platform: self.context.platform, teamID: self.context.teamID, profileID: profile.id
                )
                self.context.client.send(request) { result in
                    guard result.get(withErrorHandler: completion) != nil else { return }
                    self.createProfile(appID: self.appID, completion: completion)
                }
            } else {
                self.createProfile(appID: self.appID, completion: completion)
            }
        }
    }

}
