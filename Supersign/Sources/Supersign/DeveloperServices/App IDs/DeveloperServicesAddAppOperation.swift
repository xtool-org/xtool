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
    private func addOrFetchApp(
        bundleID: String,
        entitlements: Entitlements,
        team: DeveloperServicesTeam,
        completion: @escaping (Result<DeveloperServicesAppID, Swift.Error>) -> Void
    ) {
        let request = DeveloperServicesListAppIDsRequest(platform: context.platform, teamID: context.teamID)
        context.client.send(request) { result in
            guard let appIDs = result.get(withErrorHandler: completion) else { return }
            if let appID = appIDs.first(where: {
                bundleID == ProvisioningIdentifiers.sanitize(identifier: $0.bundleID)
            }) {
                let request = DeveloperServicesUpdateAppIDRequest(
                    platform: self.context.platform,
                    teamID: self.context.teamID,
                    appIDID: appID.id,
                    entitlements: entitlements,
                    additionalFeatures: [],
                    isFree: team.isFree
                )
                self.context.client.send(request, completion: completion)
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
                self.context.client.send(request, completion: completion)
            }
        }
    }

    /// Registers the app and returns the resultant entitlements
    private func addAppAndGetEntitlements(
        app: URL,
        team: DeveloperServicesTeam,
        // old bundle id, app id, ents
        completion: @escaping (Result<(DeveloperServicesAppID, Entitlements), Swift.Error>) -> Void
    ) {
        let infoURL = app.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
            let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let bundleID = dict["CFBundleIdentifier"] as? String,
            let executable = dict["CFBundleExecutable"] as? String else {
            return completion(.failure(Error.invalidApp(app)))
        }
        let executableURL = app.appendingPathComponent(executable)

        var entitlements: Entitlements
        // if the executable doesn't already have entitlements, that's
        // okay. We don't have to throw an error.
        if let entitlementsData = try? context.signerImpl.analyze(executable: executableURL),
            let decodedEntitlements = try? PropertyListDecoder().decode(Entitlements.self, from: entitlementsData) {
            entitlements = decodedEntitlements

            if team.isFree {
                do {
                    // re-assign rather than using updateEntitlements since the latter will
                    // retain unrecognized entitlements
                    let filtered = try entitlements.entitlements().filter { type(of: $0).isFree }
                    entitlements = try Entitlements(entitlements: filtered)
                } catch {
                    return completion(.failure(error))
                }
            }
        } else {
            do {
                entitlements = try Entitlements(entitlements: [])
            } catch {
                return completion(.failure(error))
            }
        }

        addOrFetchApp(bundleID: bundleID, entitlements: entitlements, team: team) { result in
            guard let appID = result.get(withErrorHandler: completion) else { return }

            do {
                try entitlements.update(teamID: self.context.teamID, bundleID: appID.bundleID)
                // set get-task-allow to YES, required for dev certs
                try entitlements.updateEntitlements { ents in
                    if let getTaskAllow = ents.firstIndex(where: { $0 is GetTaskAllowEntitlement }) {
                        ents[getTaskAllow] = GetTaskAllowEntitlement(rawValue: true)
                    } else {
                        ents.append(GetTaskAllowEntitlement(rawValue: true))
                    }
                }
            } catch {
                return completion(.failure(error))
            }

            if var entitlementsArray = try? entitlements.entitlements(),
                let groupsIdx = entitlementsArray.firstIndex(where: { $0 is AppGroupEntitlement }),
                let groupsEntitlement = entitlementsArray[groupsIdx] as? AppGroupEntitlement {
                let groups = groupsEntitlement.rawValue

                DeveloperServicesAssignAppGroupsOperation(
                    context: self.context,
                    groupIDs: groups,
                    appID: appID
                ).perform { result in
                    guard let newGroups = result.get(withErrorHandler: completion) else { return }
                    entitlementsArray[groupsIdx] = AppGroupEntitlement(rawValue: newGroups)

                    do {
                        try entitlements.setEntitlements(entitlementsArray)
                    } catch {
                        return completion(.failure(error))
                    }

                    completion(.success((appID, entitlements)))
                }
            } else {
                completion(.success((appID, entitlements)))
            }
        }
    }

    /// Registers the app and creates a profile. Returns the resultant entitlements as well as
    /// the profile (note that the profile does not necessarily include all of the entitlements
    /// that the app has).
    private func addApp(
        _ app: URL,
        with team: DeveloperServicesTeam,
        completion: @escaping (Result<ProvisioningInfo, Swift.Error>) -> Void
    ) {
        addAppAndGetEntitlements(app: app, team: team) { result in
            guard let (appID, entitlements) = result.get(withErrorHandler: completion) else { return }
            DeveloperServicesFetchProfileOperation(context: self.context, appID: appID).perform { result in
                guard let profile = result.get(withErrorHandler: completion) else { return }
                guard let mobileprovision = profile.mobileprovision
                    else { return completion(.failure(Mobileprovision.Error.invalidProfile)) }
                completion(.success(ProvisioningInfo(
                    newBundleID: appID.bundleID, entitlements: entitlements, mobileprovision: mobileprovision
                )))
            }
        }
    }

    private func perform(
        with team: DeveloperServicesTeam,
        completion: @escaping (Result<[URL: ProvisioningInfo], Swift.Error>) -> Void
    ) {
        var apps: [URL] = [root]
        let plugins = root.appendingPathComponent("PlugIns")
        if plugins.dirExists {
            apps += plugins.implicitContents.filter { $0.pathExtension.lowercased() == "appex" }
        }

        let grouper = RequestGrouper<(URL, ProvisioningInfo), Swift.Error>()
        for app in apps {
            grouper.add { completion in
                addApp(app, with: team) { completion($0.map { (app, $0) }) }
            }
        }
        grouper.onComplete { completion($0.map(Dictionary.init(uniqueKeysWithValues:))) }
    }

    /// Registers the app + its extensions, returning the profile and entitlements of each
    public func perform(completion: @escaping (Result<[URL: ProvisioningInfo], Swift.Error>) -> Void) {
        let request = DeveloperServicesListTeamsRequest()
        context.client.send(request) { result in
            guard let teams = result.get(withErrorHandler: completion) else { return }
            guard let team = teams.first(where: { $0.id == self.context.teamID })
                else { return completion(.failure(Error.teamNotFound(self.context.teamID))) }
            self.perform(with: team, completion: completion)
        }
    }

}
