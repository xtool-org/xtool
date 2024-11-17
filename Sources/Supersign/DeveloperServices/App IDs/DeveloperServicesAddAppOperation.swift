//
//  DeveloperServicesAddAppOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 14/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesAddAppOperation: DeveloperServicesOperation {

    public enum Error: LocalizedError {
        case invalidApp(URL)
        case teamNotFound(DeveloperServicesTeam.ID)

        public var errorDescription: String? {
            switch self {
            case .invalidApp(let url):
                return url.path.withCString {
                    String.localizedStringWithFormat(
                        NSLocalizedString(
                            "add_app_operation.error.invalid_app", value: "Invalid app: %s", comment: ""
                        ), $0
                    )
                }
            case .teamNotFound(let id):
                return id.rawValue.withCString {
                    String.localizedStringWithFormat(
                        NSLocalizedString(
                            "add_app_operation.error.team_not_found",
                            value: "A team with the ID '%s' could not be found. Please select another team.",
                            comment: ""
                        ), $0
                    )
                }
            }
        }
    }

    public let context: SigningContext
    public let root: URL
    public init(context: SigningContext, root: URL) {
        self.context = context
        self.root = root
    }

    /// Registers the app with the given entitlements
    private func upsertApp(
        bundleID: String,
        entitlements: Entitlements,
        team: DeveloperServicesTeam,
        appIDs: [String: DeveloperServicesAppID]
    ) async throws -> DeveloperServicesAppID {
        if let appID = appIDs[bundleID] {
            let request = DeveloperServicesUpdateAppIDRequest(
                platform: self.context.platform,
                teamID: self.context.teamID,
                appIDID: appID.id,
                entitlements: entitlements,
                additionalFeatures: [],
                isFree: team.isFree
            )
            return try await context.client.send(request)
        } else {
            let newBundleID = ProvisioningIdentifiers.identifier(fromSanitized: bundleID, context: self.context)
            let name = ProvisioningIdentifiers.appName(fromSanitized: bundleID)
            let request = DeveloperServicesAddAppIDRequest(
                platform: self.context.platform,
                teamID: self.context.teamID,
                bundleID: newBundleID,
                appName: name,
                entitlements: entitlements,
                additionalFeatures: [],
                isFree: team.isFree
            )
            return try await context.client.send(request)
        }
    }

    /// Registers the app and creates a profile. Returns the resultant entitlements as well as
    /// the profile (note that the profile does not necessarily include all of the entitlements
    /// that the app has).
    private func addApp(
        _ app: URL,
        team: DeveloperServicesTeam,
        appIDs: [String: DeveloperServicesAppID]
    ) async throws -> ProvisioningInfo {
        let infoURL = app.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
            let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let bundleID = dict["CFBundleIdentifier"] as? String,
            let executable = dict["CFBundleExecutable"] as? String else {
            throw Error.invalidApp(app)
        }
        let executableURL = app.appendingPathComponent(executable)

        var entitlements: Entitlements
        // if the executable doesn't already have entitlements, that's
        // okay. We don't have to throw an error.
        if let entitlementsData = try? context.signerImpl.analyze(executable: executableURL),
            let decodedEntitlements = try? PropertyListDecoder().decode(Entitlements.self, from: entitlementsData) {
            entitlements = decodedEntitlements

            if team.isFree {
                // re-assign rather than using updateEntitlements since the latter will
                // retain unrecognized entitlements
                let filtered = try entitlements.entitlements().filter { type(of: $0).isFree }
                entitlements = try Entitlements(entitlements: filtered)
            }
        } else {
            entitlements = try Entitlements(entitlements: [])
        }

        let appID = try await upsertApp(bundleID: bundleID, entitlements: entitlements, team: team, appIDs: appIDs)

        try entitlements.update(teamID: self.context.teamID, bundleID: appID.bundleID)
        // set get-task-allow to YES, required for dev certs
        try entitlements.updateEntitlements { ents in
            if let getTaskAllow = ents.firstIndex(where: { $0 is GetTaskAllowEntitlement }) {
                ents[getTaskAllow] = GetTaskAllowEntitlement(rawValue: true)
            } else {
                ents.append(GetTaskAllowEntitlement(rawValue: true))
            }
        }

        if var entitlementsArray = try? entitlements.entitlements(),
            let groupsIdx = entitlementsArray.firstIndex(where: { $0 is AppGroupEntitlement }),
            let groupsEntitlement = entitlementsArray[groupsIdx] as? AppGroupEntitlement {
            let groups = groupsEntitlement.rawValue

            let newGroups = try await DeveloperServicesAssignAppGroupsOperation(
                context: self.context,
                groupIDs: groups,
                appID: appID
            ).perform()

            entitlementsArray[groupsIdx] = AppGroupEntitlement(rawValue: newGroups)
            try entitlements.setEntitlements(entitlementsArray)
        }

        let profile = try await DeveloperServicesFetchProfileOperation(context: self.context, appID: appID).perform()
        guard let mobileprovision = profile.mobileprovision
            else { throw Mobileprovision.Error.invalidProfile }
        return ProvisioningInfo(
            newBundleID: appID.bundleID, entitlements: entitlements, mobileprovision: mobileprovision
        )
    }

    private func getTeam() async throws -> DeveloperServicesTeam {
        let request = DeveloperServicesListTeamsRequest()
        let teams = try await context.client.send(request)
        guard let team = teams.first(where: { $0.id == self.context.teamID })
            else { throw Error.teamNotFound(self.context.teamID) }
        return team
    }

    // keyed by sanitized bundle ID
    private func getCurrentAppIDs() async throws -> [String: DeveloperServicesAppID] {
        let request = DeveloperServicesListAppIDsRequest(platform: context.platform, teamID: context.teamID)
        let appIDs = try await context.client.send(request)
        let keyedIDs = appIDs.map { (ProvisioningIdentifiers.sanitize(identifier: $0.bundleID), $0) }
        return Dictionary(keyedIDs, uniquingKeysWith: { $1 })
    }

    /// Registers the app + its extensions, returning the profile and entitlements of each
    public func perform() async throws -> [URL: ProvisioningInfo] {
        var apps: [URL] = [root]
        let plugins = root.appendingPathComponent("PlugIns")
        if plugins.dirExists {
            apps += plugins.implicitContents.filter { $0.pathExtension.lowercased() == "appex" }
        }

        async let teamTask = getTeam()
        async let appIDsTask = getCurrentAppIDs()
        let (team, appIDs) = try await (teamTask, appIDsTask)

        return try await withThrowingTaskGroup(
            of: (URL, ProvisioningInfo).self,
            returning: [URL: ProvisioningInfo].self
        ) { group in
            for app in apps {
                group.addTask {
                    let info = try await addApp(app, team: team, appIDs: appIDs)
                    return (app, info)
                }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
    }

}
