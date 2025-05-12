//
//  DeveloperServicesAddAppOperation.swift
//  XKit
//
//  Created by Kabir Oberai on 14/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import DeveloperAPI

public struct DeveloperServicesAddAppOperation: DeveloperServicesOperation {

    public enum Error: LocalizedError {
        case invalidApp(URL)

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
            }
        }
    }

    public let context: SigningContext
    public let signingInfo: SigningInfo
    public let root: URL
    public init(context: SigningContext, signingInfo: SigningInfo, root: URL) {
        self.context = context
        self.signingInfo = signingInfo
        self.root = root
    }

    /// Registers the app with the given entitlements
    private func upsertApp(
        bundleID: String,
        entitlements: Entitlements,
        isFreeTeam: Bool,
        appIDs: [String: Components.Schemas.BundleId]
    ) async throws -> Components.Schemas.BundleId {
        let appID: Components.Schemas.BundleId
        if let existing = appIDs[bundleID] {
            appID = existing
        } else {
            let newBundleID = ProvisioningIdentifiers.identifier(fromSanitized: bundleID, context: self.context)
            let name = ProvisioningIdentifiers.appName(fromSanitized: bundleID)
            let createResponse = try await context.developerAPIClient.bundleIdsCreateInstance(
                body: .json(
                    .init(
                        data: .init(
                            _type: .bundleIds,
                            attributes: .init(
                                name: name,
                                platform: .ios,
                                identifier: newBundleID
                            )
                        )
                    )
                )
            )
            appID = try createResponse.created.body.json.data
        }

        let existingCapabilitiesList = try await context.developerAPIClient
            .bundleIdsBundleIdCapabilitiesGetToManyRelated(.init(path: .init(id: appID.id)))
            .ok.body.json.data
        let existingCapabilities = [Components.Schemas.CapabilityType: Components.Schemas.BundleIdCapability](
            existingCapabilitiesList.compactMap { cap in
                (cap.attributes?.capabilityType).map { ($0, cap) }
            },
            uniquingKeysWith: { $1 }
        )

        let wantedCapabilitiesList = try entitlements.entitlements().compactMap(\.anyCapability)
        let wantedCapabilities = [Components.Schemas.CapabilityType: [Components.Schemas.CapabilitySetting]](
            wantedCapabilitiesList.map { ($0.capabilityType, $0.settings ?? []) },
            uniquingKeysWith: { $1 }
        )

        for (typ, cap) in existingCapabilities {
            if let wantedSettings = wantedCapabilities[typ] {
                if wantedSettings != (cap.attributes?.settings ?? []) {
                    _ = try await context.developerAPIClient.bundleIdCapabilitiesUpdateInstance(
                        path: .init(id: cap.id),
                        body: .json(
                            .init(
                                data: .init(
                                    _type: .bundleIdCapabilities,
                                    id: cap.id,
                                    attributes: .init(
                                        capabilityType: typ,
                                        settings: wantedSettings
                                    )
                                )
                            )
                        )
                    )
                    .ok
                }
            } else {
                // DeveloperServices doesn't allow deleting these capabilities
                let requiredCapabilities: Set<Components.Schemas.CapabilityType> = [.inAppPurchase]
                if let capType = cap.attributes?.capabilityType, !requiredCapabilities.contains(capType) {
                    _ = try await context.developerAPIClient
                        .bundleIdCapabilitiesDeleteInstance(path: .init(id: cap.id))
                        .noContent
                }
            }
        }
        for (typ, settings) in wantedCapabilities {
            guard existingCapabilities[typ] == nil else { continue }
            _ = try await context.developerAPIClient.bundleIdCapabilitiesCreateInstance(
                body: .json(.init(data: .init(
                    _type: .bundleIdCapabilities,
                    attributes: .init(
                        capabilityType: typ,
                        settings: settings
                    ),
                    relationships: .init(
                        bundleId: .init(
                            data: .init(
                                _type: .bundleIds,
                                id: appID.id
                            )
                        ),
                        // not public but required when using ds2 API
                        capability: .init(
                            data: .init(
                                _type: .capabilities,
                                id: typ
                            )
                        )
                    )
                )))
            )
            .created.body
        }

        return appID
    }

    /// Registers the app and creates a profile. Returns the resultant entitlements as well as
    /// the profile (note that the profile does not necessarily include all of the entitlements
    /// that the app has).
    private func addApp(
        _ app: URL,
        isFreeTeam: Bool,
        appIDs: [String: Components.Schemas.BundleId]
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
        if let entitlementsData = try? await context.signerImpl.analyze(executable: executableURL),
            let decodedEntitlements = try? PropertyListDecoder().decode(Entitlements.self, from: entitlementsData) {
            entitlements = decodedEntitlements

            if isFreeTeam {
                // re-assign rather than using updateEntitlements since the latter will
                // retain unrecognized entitlements
                let filtered = try entitlements.entitlements().filter { $0.anyCapability?.isFree != false }
                entitlements = try Entitlements(entitlements: filtered)
            }
        } else {
            entitlements = try Entitlements(entitlements: [])
        }

        let appID = try await upsertApp(bundleID: bundleID, entitlements: entitlements, isFreeTeam: isFreeTeam, appIDs: appIDs)
        let newBundleID = appID.attributes!.identifier!

        let teamID = try signingInfo.certificate.teamID()
        try entitlements.update(
            teamID: .init(rawValue: teamID),
            bundleID: newBundleID
        )
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

            if let operation = DeveloperServicesAssignAppGroupsOperation(
                context: self.context,
                groupIDs: groups,
                appID: appID
            ) {
                let newGroups = try await operation.perform()
                entitlementsArray[groupsIdx] = AppGroupEntitlement(rawValue: newGroups)
                try entitlements.setEntitlements(entitlementsArray)
            }
        }

        let mobileprovision = try await DeveloperServicesFetchProfileOperation(
            context: self.context,
            bundleID: newBundleID,
            signingInfo: signingInfo
        ).perform()

        return ProvisioningInfo(
            newBundleID: newBundleID,
            entitlements: entitlements,
            mobileprovision: mobileprovision
        )
    }

    // keyed by sanitized bundle ID
    private func getCurrentAppIDs() async throws -> [String: Components.Schemas.BundleId] {
        let bundleIDs = try await context.developerAPIClient.bundleIdsGetCollection().ok.body.json.data
        let keyedIDs = bundleIDs
            .compactMap { id -> (String, Components.Schemas.BundleId)? in
                guard let bundleID = id.attributes?.identifier else { return nil }
                return (ProvisioningIdentifiers.sanitize(identifier: bundleID), id)
            }
        return Dictionary(keyedIDs, uniquingKeysWith: { $1 })
    }

    /// Registers the app + its extensions, returning the profile and entitlements of each
    public func perform() async throws -> [URL: ProvisioningInfo] {
        var apps: [URL] = [root]
        let plugins = root.appendingPathComponent("PlugIns")
        if plugins.dirExists {
            apps += plugins.implicitContents.filter { $0.pathExtension.lowercased() == "appex" }
        }

        async let isFreeTeamTask = context.auth.team()?.isFree == true
        async let appIDsTask = getCurrentAppIDs()
        let (isFreeTeam, appIDs) = try await (isFreeTeamTask, appIDsTask)

        return try await withThrowingTaskGroup(
            of: (URL, ProvisioningInfo).self,
            returning: [URL: ProvisioningInfo].self
        ) { group in
            for app in apps {
                group.addTask {
                    let info = try await addApp(app, isFreeTeam: isFreeTeam, appIDs: appIDs)
                    return (app, info)
                }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
    }

}
