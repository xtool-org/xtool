//
//  DeveloperServicesUpdateAppIDRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesUpdateAppIDRequest: DeveloperServicesPlatformRequest {

    public struct Response: Decodable {
        let appId: DeveloperServicesAppID
    }
    public typealias Value = DeveloperServicesAppID

    public let platform: DeveloperServicesPlatform
    public let teamID: DeveloperServicesTeam.ID
    public let appIDID: DeveloperServicesAppID.ID
    public let entitlements: Entitlements
    public let additionalFeatures: [DeveloperServicesFeature]
    public let isFree: Bool

    var subAction: String { return "updateAppId" }
    var subParameters: [String: Any] {
        var parameters: [String: Any] = [
            "teamId": teamID.rawValue,
            "appIdId": appIDID.rawValue
        ]

        DeveloperServicesAppIDRequestApplier.apply(
            entitlements: entitlements,
            additionalFeatures: additionalFeatures,
            to: &parameters,
            isFree: isFree
        )

        return parameters
    }

    public func parse(_ response: Response, completion: @escaping (Result<Value, Error>) -> Void) {
        completion(.success(response.appId))
    }

    public init(
        platform: DeveloperServicesPlatform,
        teamID: DeveloperServicesTeam.ID,
        appIDID: DeveloperServicesAppID.ID,
        entitlements: Entitlements,
        additionalFeatures: [DeveloperServicesFeature],
        isFree: Bool
    ) {
        self.platform = platform
        self.teamID = teamID
        self.appIDID = appIDID
        self.entitlements = entitlements
        self.additionalFeatures = additionalFeatures
        self.isFree = isFree
    }

}
