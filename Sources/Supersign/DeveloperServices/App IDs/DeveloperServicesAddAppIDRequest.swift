//
//  DeveloperServicesAddAppIDRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesAddAppIDRequest: DeveloperServicesPlatformRequest {

    public struct Response: Decodable, Sendable {
        let appId: DeveloperServicesAppID
    }
    public typealias Value = DeveloperServicesAppID

    public let platform: DeveloperServicesPlatform
    public let teamID: DeveloperServicesTeam.ID
    public let bundleID: String
    public let appName: String
    public let entitlements: Entitlements
    public let additionalFeatures: [DeveloperServicesFeature]
    public let isFree: Bool

    var subAction: String { return "addAppId" }
    var subParameters: [String: Any] {
        var parameters: [String: Any] = [
            "teamId": teamID.rawValue,
            "identifier": bundleID,
            "name": appName
        ]

        DeveloperServicesAppIDRequestApplier.apply(
            entitlements: entitlements,
            additionalFeatures: additionalFeatures,
            to: &parameters,
            isFree: isFree
        )

        return parameters
    }

    public func parse(_ response: Response) -> DeveloperServicesAppID {
        response.appId
    }

    public init(
        platform: DeveloperServicesPlatform,
        teamID: DeveloperServicesTeam.ID,
        bundleID: String,
        appName: String,
        entitlements: Entitlements,
        additionalFeatures: [DeveloperServicesFeature],
        isFree: Bool
    ) {
        self.platform = platform
        self.teamID = teamID
        self.bundleID = bundleID
        self.appName = appName
        self.entitlements = entitlements
        self.additionalFeatures = additionalFeatures
        self.isFree = isFree
    }

}
