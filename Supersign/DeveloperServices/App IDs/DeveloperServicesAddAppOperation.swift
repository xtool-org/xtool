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

        public var errorDescription: String? {
            switch self {
            case .invalidApp(let url):
                return String.localizedStringWithFormat(
                    NSLocalizedString(
                        "app_id_request_helper.error.invalid_app", value: "Invalid app: %@", comment: ""
                    ), url.path
                )
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
        completion: @escaping (Result<DeveloperServicesAppID, Swift.Error>) -> Void
    ) {
        let request = DeveloperServicesListAppIDsRequest(platform: context.platform, teamID: context.team.id)
        context.client.send(request) { result in
            guard let appIDs = result.get(withErrorHandler: completion) else { return }
            if let appID = appIDs.first(where: {
                bundleID == ProvisioningIdentifiers.sanitize(identifier: $0.bundleID)
            }) {
                let request = DeveloperServicesUpdateAppIDRequest(
                    platform: self.context.platform,
                    teamID: self.context.team.id,
                    appIDID: appID.id,
                    entitlements: entitlements,
                    additionalFeatures: [],
                    isFree: self.context.team.isFree
                )
                self.context.client.send(request, completion: completion)
            } else {
                let newBundleID = ProvisioningIdentifiers.identifier(fromSanitized: bundleID)
                let name = ProvisioningIdentifiers.appName(fromSanitized: bundleID)
                let request = DeveloperServicesAddAppIDRequest(
                    platform: self.context.platform,
                    teamID: self.context.team.id,
                    bundleID: newBundleID,
                    appName: name,
                    entitlements: entitlements,
                    additionalFeatures: [],
                    isFree: self.context.team.isFree
                )
                self.context.client.send(request, completion: completion)
            }
        }
    }

    /// Registers the app and returns the resultant entitlements
    private func addAppAndGetEntitlements(
        app: URL,
        // old bundle id, app id, ents
        completion: @escaping (Result<(DeveloperServicesAppID, Entitlements), Swift.Error>) -> Void
    ) {
        let infoURL = app.appendingPathComponent("Info.plist")
        guard let dict = NSDictionary(contentsOf: infoURL),
            let bundleID = dict[kCFBundleIdentifierKey as String] as? String,
            let executable = dict[kCFBundleExecutableKey as String] as? String else {
            return completion(.failure(Error.invalidApp(app)))
        }
        let executableURL = app.appendingPathComponent(executable)

        var entitlements: Entitlements
        // if the executable doesn't already have entitlements, that's
        // okay. We don't have to throw an error.
        if let entitlementsData = context.signerImpl.analyze(executable: executableURL),
            let decodedEntitlements = try? PropertyListDecoder().decode(Entitlements.self, from: entitlementsData) {
            entitlements = decodedEntitlements

            if context.team.isFree {
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

        addOrFetchApp(bundleID: bundleID, entitlements: entitlements) { result in
            guard let appID = result.get(withErrorHandler: completion) else { return }

            do {
                try entitlements.update(teamID: self.context.team.id, bundleID: appID.bundleID)
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
        completion: @escaping (Result<ProvisioningInfo, Swift.Error>) -> Void
    ) {
        addAppAndGetEntitlements(app: app) { result in
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

    /// Registers the app + its extensions, returning the profile and entitlements of each
    public func perform(completion: @escaping (Result<[URL: ProvisioningInfo], Swift.Error>) -> Void) {
        var apps: [URL] = [root]
        let plugins = root.appendingPathComponent("PlugIns")
        if plugins.dirExists {
            apps += plugins.implicitContents.filter { $0.pathExtension.lowercased() == "appex" }
        }

        let grouper = RequestGrouper<(URL, ProvisioningInfo), Swift.Error>()
        for app in apps {
            grouper.add { completion in
                addApp(app) { completion($0.map { (app, $0) }) }
            }
        }
        grouper.onComplete { completion($0.map(Dictionary.init(uniqueKeysWithValues:))) }
    }

}
