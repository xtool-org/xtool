//
//  DeveloperServicesAppIDRequestApplier.swift
//  Supersign
//
//  Created by Kabir Oberai on 11/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

enum DeveloperServicesAppIDRequestApplier {
    static func apply(
        entitlements: Entitlements, additionalFeatures: [DeveloperServicesFeature],
        to dict: inout [String: Any], isFree: Bool
    ) {
        var entitlements = entitlements
        try? entitlements.updateEntitlements {
            $0.removeAll {
                let type = Swift.type(of: $0)
                return !type.canList || (isFree && !type.isFree)
            }
        }
        dict["entitlements"] = try? entitlements.plistValue()

        let entFeatures = (try? entitlements.entitlements().compactMap { $0.feature() }) ?? []
        let allFeatures = entFeatures + additionalFeatures
        guard let features = try? DeveloperServicesFeatures(values: allFeatures).plistValue() as? [String: Any]
            else { return }
        dict.merge(features) { a, _ in a }
    }
}
