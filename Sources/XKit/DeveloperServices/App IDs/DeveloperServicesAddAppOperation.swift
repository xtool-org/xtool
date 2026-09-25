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
    public let platform: ProvisioningPlatform
    public init(
        context: SigningContext,
        signingInfo: SigningInfo,
        root: URL,
        platform: ProvisioningPlatform = .iOS
    ) {
        self.context = context
        self.signingInfo = signingInfo
        self.root = root
        self.platform = platform
    }

    private func infoPlistURL(for app: URL) -> URL {
        let macInfoPlist = app.appendingPathComponent("Contents").appendingPathComponent("Info.plist")
        if FileManager.default.fileExists(atPath: macInfoPlist.path) {
            return macInfoPlist
        }
        return app.appendingPathComponent("Info.plist")
    }

    private func executableURL(for app: URL, executableName: String) -> URL {
        let macExecutable = app
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent(executableName)
        if FileManager.default.fileExists(atPath: macExecutable.path) {
            return macExecutable
        }
        return app.appendingPathComponent(executableName)
    }

    private func sidecarEntitlementsURLs(for app: URL) -> [URL] {
        [
            app.appendingPathComponent("archived-expanded-entitlements.xcent"),
            app.appendingPathComponent("Contents").appendingPathComponent("archived-expanded-entitlements.xcent")
        ]
    }

    private func readEntitlements(at url: URL) -> Entitlements? {
        guard let entitlementsData = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(Entitlements.self, from: entitlementsData)
    }

    private func loadEntitlements(for app: URL, executableURL: URL) async throws -> Entitlements {
        for sidecarURL in sidecarEntitlementsURLs(for: app) where FileManager.default.fileExists(atPath: sidecarURL.path) {
            if let sidecarEntitlements = readEntitlements(at: sidecarURL) {
                return sidecarEntitlements
            }
        }

        if let entitlementsData = try? await context.signer.analyze(executable: executableURL),
            let analyzedEntitlements = try? PropertyListDecoder().decode(Entitlements.self, from: entitlementsData) {
            return analyzedEntitlements
        }

        return try Entitlements(entitlements: [])
    }

    private func upsertApp(
        bundleID: String,
        entitlements: Entitlements,
        isFreeTeam: Bool
    ) async throws -> Components.Schemas.BundleId {
        try await DeveloperServicesUpsertAppOperation(
            context: context,
            originalBundleID: bundleID,
            newBundleID: ProvisioningIdentifiers.identifier(fromSanitized: bundleID, context: context),
            entitlements: entitlements,
            platform: platform
        ).perform()
    }

    /// Registers the app and creates a profile. Returns the resultant entitlements as well as
    /// the profile (note that the profile does not necessarily include all of the entitlements
    /// that the app has).
    private func addApp(
        _ app: URL,
        isFreeTeam: Bool
    ) async throws -> ProvisioningInfo {
        let infoURL = infoPlistURL(for: app)
        guard let data = try? Data(contentsOf: infoURL),
            let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let bundleID = dict["CFBundleIdentifier"] as? String,
            let executable = dict["CFBundleExecutable"] as? String else {
            throw Error.invalidApp(app)
        }
        let executableURL = executableURL(for: app, executableName: executable)

        var entitlements = try await loadEntitlements(for: app, executableURL: executableURL)
        if isFreeTeam {
            // re-assign rather than using updateEntitlements since the latter will
            // retain unrecognized entitlements
            let filtered = try entitlements.entitlements().filter { $0.anyCapability?.isFree != false }
            entitlements = try Entitlements(entitlements: filtered)
        }

        let appID = try await upsertApp(bundleID: bundleID, entitlements: entitlements, isFreeTeam: isFreeTeam)
        let newBundleID = appID.attributes!.identifier!

        let teamID = try signingInfo.certificate.teamID()
        try entitlements.update(
            teamID: .init(rawValue: teamID),
            bundleID: newBundleID
        )
        // set get-task-allow to YES, required for dev certs
        if platform == .macOS {
            // macOS expects `com.apple.application-identifier` and
            // `com.apple.security.get-task-allow` in the app entitlements.
            try entitlements.updateEntitlements { ents in
                ents.removeAll {
                    $0 is ApplicationIdentifierEntitlement
                        || $0 is MacApplicationIdentifierEntitlement
                        || $0 is GetTaskAllowEntitlement
                        || $0 is MacGetTaskAllowEntitlement
                        || $0 is KeychainAccessGroupsEntitlement
                }
                ents.append(MacApplicationIdentifierEntitlement(rawValue: "\(teamID).\(newBundleID)"))
                ents.append(MacGetTaskAllowEntitlement(rawValue: true))
                ents.append(KeychainAccessGroupsEntitlement(rawValue: ["\(teamID).*"]))
            }
        } else {
            try entitlements.updateEntitlements { ents in
                if let getTaskAllow = ents.firstIndex(where: { $0 is GetTaskAllowEntitlement }) {
                    ents[getTaskAllow] = GetTaskAllowEntitlement(rawValue: true)
                } else {
                    ents.append(GetTaskAllowEntitlement(rawValue: true))
                }
            }
        }

        if var entitlementsArray = try? entitlements.entitlements(),
            let groupsIdx = entitlementsArray.firstIndex(where: { $0 is AppGroupEntitlement }),
            let groupsEntitlement = entitlementsArray[groupsIdx] as? AppGroupEntitlement {
            let groups = groupsEntitlement.rawValue

            if let operation = DeveloperServicesAssignAppGroupsOperation(
                context: self.context,
                groupIDs: groups,
                appID: appID,
                platform: platform
            ) {
                let newGroups = try await operation.perform()
                entitlementsArray[groupsIdx] = AppGroupEntitlement(rawValue: newGroups)
                try entitlements.setEntitlements(entitlementsArray)
            }
        }

        let mobileprovision = try await DeveloperServicesFetchProfileOperation(
            context: self.context,
            bundleID: newBundleID,
            signingInfo: signingInfo,
            platform: platform
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

        for pluginsDir in ["PlugIns", "Extensions", "Contents/PlugIns", "Contents/Extensions"] {
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
