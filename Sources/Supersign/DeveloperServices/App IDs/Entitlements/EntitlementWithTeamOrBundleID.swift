//
//  EntitlementWithTeamOrBundleID.swift
//  Supersign
//
//  Created by Kabir Oberai on 12/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

protocol EntitlementWithTeamOrBundleID: Entitlement {
    mutating func update(teamID: DeveloperServicesTeam.ID, bundleID: String)
}

extension ApplicationIdentifierEntitlement: EntitlementWithTeamOrBundleID {
    mutating func update(teamID: DeveloperServicesTeam.ID, bundleID: String) {
        self.rawValue = "\(teamID.rawValue).\(bundleID)"
    }
}

extension TeamIdentifierEntitlement: EntitlementWithTeamOrBundleID {
    mutating func update(teamID: DeveloperServicesTeam.ID, bundleID: String) {
        self.rawValue = teamID.rawValue
    }
}

extension KeychainAccessGroupsEntitlement: EntitlementWithTeamOrBundleID {
    mutating func update(teamID: DeveloperServicesTeam.ID, bundleID: String) {
        rawValue = ["\(teamID.rawValue).\(bundleID)"]
    }
}

extension Entitlements {

    public mutating func update(teamID: DeveloperServicesTeam.ID, bundleID: String) throws {
        try updateEntitlements { entitlements in
            for entitlementIndex in entitlements.indices {
                if var copy = entitlements[entitlementIndex] as? EntitlementWithTeamOrBundleID {
                    copy.update(teamID: teamID, bundleID: bundleID)
                    entitlements[entitlementIndex] = copy
                }
            }
        }
    }

}
