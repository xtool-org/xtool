//
//  EntitlementWithTeamOrBundleID.swift
//  Supersign
//
//  Created by Kabir Oberai on 12/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

protocol EntitlementWithTeamOrBundleID: Entitlement {
    init(teamID: DeveloperServicesTeam.ID, bundleID: String)
}

extension ApplicationIdentifierEntitlement: EntitlementWithTeamOrBundleID {
    init(teamID: DeveloperServicesTeam.ID, bundleID: String) {
        self.rawValue = "\(teamID.rawValue).\(bundleID)"
    }
}

extension TeamIdentifierEntitlement: EntitlementWithTeamOrBundleID {
    init(teamID: DeveloperServicesTeam.ID, bundleID: String) {
        self.rawValue = teamID.rawValue
    }
}

extension KeychainAccessGroupsEntitlement: EntitlementWithTeamOrBundleID {
    init(teamID: DeveloperServicesTeam.ID, bundleID: String) {
        rawValue = ["\(teamID.rawValue).\(bundleID)"]
    }
}

extension Entitlements {

    public mutating func update(teamID: DeveloperServicesTeam.ID, bundleID: String) throws {
        let teamOrBundleIDTypes = EntitlementContainer.supportedTypes
            .compactMap { $0 as? EntitlementWithTeamOrBundleID.Type }
        let teamOrBundleIDSet = Set(teamOrBundleIDTypes.map(ObjectIdentifier.init))

        try updateEntitlements { entitlements in
            entitlements.removeAll { teamOrBundleIDSet.contains(ObjectIdentifier(type(of: $0))) }
            entitlements += teamOrBundleIDTypes.map { $0.init(teamID: teamID, bundleID: bundleID) }
        }
    }

}
