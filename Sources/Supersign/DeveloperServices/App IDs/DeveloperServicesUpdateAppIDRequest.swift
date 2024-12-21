//
//  DeveloperServicesUpdateAppIDRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesUpdateAppIDRequest: DeveloperServicesPlatformRequest {

    public typealias Value = EmptyResponse

    public let platform: DeveloperServicesPlatform
    public let teamID: DeveloperServicesTeam.ID
    public let appIDID: String
    public let entitlements: Entitlements
    public let additionalFeatures: [DeveloperServicesFeature]
    public let isFree: Bool

    var subAction: String { return "updateAppId" }
    var subParameters: [String: Any] {
        var parameters: [String: Any] = [
            "teamId": teamID.rawValue,
            "appIdId": appIDID
        ]

        var entitlements = entitlements
        try? entitlements.updateEntitlements {
            $0.removeAll {
                let type = Swift.type(of: $0)
                return !type.canList || (isFree && !type.isFree)
            }
        }
        parameters["entitlements"] = try? entitlements.plistValue()

        let entFeatures = (try? entitlements.entitlements().compactMap { $0.feature() }) ?? []
        let allFeatures = entFeatures + additionalFeatures
        if let features = try? DeveloperServicesFeatures(values: allFeatures).plistValue() as? [String: Any] {
            parameters.merge(features) { a, _ in a }
        }

        return parameters
    }

    public init(
        platform: DeveloperServicesPlatform,
        teamID: DeveloperServicesTeam.ID,
        appIDID: String,
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
