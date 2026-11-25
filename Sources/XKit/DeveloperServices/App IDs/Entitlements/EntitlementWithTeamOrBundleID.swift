//
//  EntitlementWithTeamOrBundleID.swift
//  XKit
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
            // an app shares its keychain with its extensions through a group they all list, so
            // keep the groups the build asked for when they belong to the team: the development
            // profile grants `<team>.*`. A wildcard is not a group an app can name.
            let teamPrefix = "\(teamID.rawValue)."
            let sharedGroups = entitlements
                .compactMap { ($0 as? KeychainAccessGroupsEntitlement)?.rawValue }
                .joined()
                .filter { $0.hasPrefix(teamPrefix) && !$0.contains("*") }

            entitlements.removeAll { teamOrBundleIDSet.contains(ObjectIdentifier(type(of: $0))) }
            entitlements += teamOrBundleIDTypes.map { $0.init(teamID: teamID, bundleID: bundleID) }

            guard !sharedGroups.isEmpty,
                  let index = entitlements.firstIndex(where: { $0 is KeychainAccessGroupsEntitlement }),
                  let own = entitlements[index] as? KeychainAccessGroupsEntitlement
            else { return }
            // the app's own group stays first: items added without a group go to the first one,
            // so a shared group never becomes the default.
            var groups = own.rawValue
            for group in sharedGroups where !groups.contains(group) {
                groups.append(group)
            }
            entitlements[index] = KeychainAccessGroupsEntitlement(rawValue: groups)
        }
    }

}
