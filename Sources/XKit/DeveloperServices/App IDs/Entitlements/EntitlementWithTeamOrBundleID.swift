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
            let requestedKeychainGroups = entitlements.lazy
                .compactMap { $0 as? KeychainAccessGroupsEntitlement }
                .first?.rawValue ?? []
            entitlements.removeAll { teamOrBundleIDSet.contains(ObjectIdentifier(type(of: $0))) }
            entitlements += teamOrBundleIDTypes.map { $0.init(teamID: teamID, bundleID: bundleID) }

            // Keep any shared keychain groups the app asked for (keychain sharing between an
            // app and its extensions), re-scoped to the signing team. The app's own group stays first,
            // since it is the default access group.
            let shared = Self.sharedKeychainGroups(requestedKeychainGroups, teamID: teamID, bundleID: bundleID)
            if let index = entitlements.firstIndex(where: { $0 is KeychainAccessGroupsEntitlement }),
               let own = entitlements[index] as? KeychainAccessGroupsEntitlement {
                let extra = shared.filter { !own.rawValue.contains($0) }
                if !extra.isEmpty {
                    entitlements[index] = KeychainAccessGroupsEntitlement(rawValue: own.rawValue + extra)
                }
            }
        }
    }

    /// The keychain groups in `requested` re-scoped to `teamID`, in order and without duplicates.
    ///
    /// A group may carry a team ID prefix (`ABCDE12345.com.example.shared`, e.g. from an IPA signed by another
    /// team), use Xcode's build-setting spelling (`$(AppIdentifierPrefix)com.example.shared`), or have no prefix at
    /// all: the build expands `$(AppIdentifierPrefix)` to nothing because the team is only known once xtool signs.
    /// Each becomes `<teamID>.com.example.shared`, which a development profile's `<teamID>.*` keychain group allows.
    /// The app's own former group (the one `bundleID` replaces) and wildcards are dropped.
    static func sharedKeychainGroups(
        _ requested: [String],
        teamID: DeveloperServicesTeam.ID,
        bundleID: String
    ) -> [String] {
        let placeholders = ["$(AppIdentifierPrefix)", "$(TeamIdentifierPrefix)"]
        var result: [String] = []
        for group in requested where !group.contains("*") {
            let suffix: Substring
            if let placeholder = placeholders.first(where: { group.hasPrefix($0) }) {
                suffix = group.dropFirst(placeholder.count)
            } else if let dot = group.firstIndex(of: "."), isTeamID(group[..<dot]) {
                suffix = group[group.index(after: dot)...]
            } else {
                suffix = Substring(group)
            }
            guard !suffix.isEmpty, suffix != bundleID, !bundleID.hasSuffix(".\(suffix)") else { continue }
            let rescoped = "\(teamID.rawValue).\(suffix)"
            if !result.contains(rescoped) { result.append(rescoped) }
        }
        return result
    }

    /// Apple team IDs (and App ID prefixes) are 10 uppercase letters or digits.
    private static func isTeamID(_ string: Substring) -> Bool {
        string.count == 10 && string.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

}
