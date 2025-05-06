//
//  ProfileManager.swift
//  Supersign
//
//  Created by Kabir Oberai on 25/03/21.
//  Copyright © 2021 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

public final class ProfileManager {

    private let client: MISAgentClient
    private let version: String

    private lazy var ge9_3: Bool = {
        let components = version.split(separator: ".")
        guard !components.isEmpty, let major = Int(components[0]) else { return false }
        if major > 9 {
            return true
        } else if major < 9 {
            return false
        }
        guard components.count >= 2, let minor = Int(components[1]) else { return false }
        return minor >= 3
    }()

    public init(connection: Connection) async throws {
        self.client = try await connection.startClient()
        self.version = try connection.client.value(ofType: String.self, forDomain: nil, key: "ProductVersion")
    }

    private func allProfiles() throws -> [Mobileprovision] {
        try (ge9_3 ? client.profiles() : client.profilesLegacy())
            .map(Mobileprovision.init(data:))
    }

    private func parse(profiles: [Mobileprovision]) throws -> [String: [(Mobileprovision, Mobileprovision.Digest)]] {
        let pairs = try profiles.compactMap { (p: Mobileprovision) -> (String, (Mobileprovision, Mobileprovision.Digest))? in
            let d = try p.digest()
            let ents = try d.entitlements.entitlements()
            guard let appID = ents.lazy.compactMap({ $0 as? ApplicationIdentifierEntitlement }).first
                else { return nil }
            return (appID.rawValue, (p, d))
        }
        return Dictionary(grouping: pairs) { $0.0 }.mapValues { $0.map { $0.1 } }
    }

    public func install(profiles: [Mobileprovision]) throws {
        let toInstall = try parse(profiles: profiles)
        let installed = try parse(profiles: allProfiles())

        for (bundleID, profiles) in toInstall {
            guard profiles.count == 1 else {
                print("Unexpected # of profiles for \(bundleID): \(profiles.count). Skipping.")
                continue
            }
            let profile = profiles[0]
            let installedProfiles = installed[bundleID] ?? []
            for installedProfile in installedProfiles {
                print("Removing \(installedProfile.1.uuid) for \(bundleID)")
                try client.removeProfile(withUUID: installedProfile.1.uuid)
            }
            print("Installing profile with UUID \(profile.1.uuid)")
            try client.install(profile: profile.0.data())
        }
    }

}
