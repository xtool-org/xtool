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
        isFreeTeam: Bool
    ) async throws -> Components.Schemas.BundleId {
        let newBundleID = ProvisioningIdentifiers.identifier(fromSanitized: bundleID, context: self.context)

        let existing = try await context.developerAPIClient
            .bundleIdsGetCollection(query: .init(
                filter_lbrack_identifier_rbrack_: [bundleID]
            ))
            .ok.body.json.data
            // filter[identifier] is a prefix filter so we need to manually upgrade to equality
            .first(where: { $0.attributes?.identifier == newBundleID })

        let appID: Components.Schemas.BundleId
        if let existing {
            appID = existing
        } else {
            let name = ProvisioningIdentifiers.appName(fromSanitized: bundleID)
            let createResponse = try await context.developerAPIClient.bundleIdsCreateInstance(
                body: .json(
                    .init(
                        data: .init(
                            _type: .bundleIds,
                            attributes: .init(
                                name: name,
                                platform: .init(.ios),
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
                let requiredCapabilities: Set<Components.Schemas.CapabilityType.Value1Payload> = [.inAppPurchase]
                if let capType = cap.attributes?.capabilityType?.value1, !requiredCapabilities.contains(capType) {
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
        isFreeTeam: Bool
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
        if let entitlementsData = try? await context.signer.analyze(executable: executableURL),
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

        let appID = try await upsertApp(bundleID: bundleID, entitlements: entitlements, isFreeTeam: isFreeTeam)
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

    /// Registers the app + its extensions, returning the profile and entitlements of each
    public func perform() async throws -> [URL: ProvisioningInfo] {
        var apps: [URL] = [root]

        for pluginsDir in ["PlugIns", "Extensions"] {
            let plugins = root.appendingPathComponent(pluginsDir)
            guard plugins.dirExists else { continue }
            apps += plugins.implicitContents.filter { $0.pathExtension.lowercased() == "appex" }
        }

        let isFreeTeam = try await context.auth.team()?.isFree == true

        return try await withThrowingTaskGroup(
            of: (URL, ProvisioningInfo).self,
            returning: [URL: ProvisioningInfo].self
        ) { group in
            for app in apps {
                group.addTask {
                    let info = try await addApp(app, isFreeTeam: isFreeTeam)
                    return (app, info)
                }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
    }

}
