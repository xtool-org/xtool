//
//  Mobileprovision.swift
//  Supercharge
//
//  Created by Kabir Oberai on 07/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import CXKit

public final class Mobileprovision: @unchecked Sendable {

    public enum Error: Swift.Error {
        case invalidProfile
    }

    /// The distribution method a profile is meant for, as Xcode's export dialog would call it.
    public enum Kind: Sendable, Equatable {
        case development
        case adHoc
        case appStore
        case enterprise
    }

    public struct Digest: Decodable, Sendable {
        public let name: String
        public let uuid: String
        public let teamIdentifiers: [DeveloperServicesTeam.ID]
        public let creationDate: Date
        public let expirationDate: Date
        /// The UDIDs the profile is restricted to. Empty for App Store and Enterprise profiles.
        public let devices: [String]
        public let platforms: [String]
        public let certificates: [Certificate]
        public let entitlements: Entitlements
        public let kind: Kind

        private enum CodingKeys: String, CodingKey {
            case name = "Name"
            case uuid = "UUID"
            case teamIdentifiers = "TeamIdentifier"
            case creationDate = "CreationDate"
            case expirationDate = "ExpirationDate"
            case devices = "ProvisionedDevices"
            case provisionsAllDevices = "ProvisionsAllDevices"
            case platforms = "Platform"
            case certificates = "DeveloperCertificates"
            case entitlements = "Entitlements"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            uuid = try container.decode(String.self, forKey: .uuid)
            teamIdentifiers = try container.decode([DeveloperServicesTeam.ID].self, forKey: .teamIdentifiers)
            creationDate = try container.decode(Date.self, forKey: .creationDate)
            expirationDate = try container.decode(Date.self, forKey: .expirationDate)
            // App Store and Enterprise profiles have no ProvisionedDevices key
            let provisionedDevices = try container.decodeIfPresent([String].self, forKey: .devices)
            devices = provisionedDevices ?? []
            platforms = try container.decodeIfPresent([String].self, forKey: .platforms) ?? []
            certificates = try container.decode([Certificate].self, forKey: .certificates)
            entitlements = try container.decode(Entitlements.self, forKey: .entitlements)

            let provisionsAllDevices = try container.decodeIfPresent(Bool.self, forKey: .provisionsAllDevices) ?? false
            if provisionsAllDevices {
                kind = .enterprise
            } else if provisionedDevices == nil {
                kind = .appStore
            } else {
                let getTaskAllow = try entitlements.entitlements()
                    .compactMap { $0 as? GetTaskAllowEntitlement }
                    .first?.rawValue ?? false
                kind = getTaskAllow ? .development : .adHoc
            }
        }
    }

    let raw: mobileprovision_t

    public init(data: Data) throws {
        guard let profile: mobileprovision_t = data.withUnsafeBytes({
            guard let base = $0.baseAddress else { return nil }
            return mobileprovision_create_from_data(base, $0.count)
        }) else {
            throw Error.invalidProfile
        }
        self.raw = profile
    }

    deinit {
        mobileprovision_free(raw)
    }

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public func digest() throws -> Digest {
        var len = 0
        guard let ptr = mobileprovision_get_digest(raw, &len), len > 0 else {
            throw Error.invalidProfile
        }
        let data = Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: ptr),
            count: len,
            deallocator: .none
        )
        return try PropertyListDecoder().decode(Digest.self, from: data)
    }

    public func data() throws -> Data {
        try Data { mobileprovision_copy_data(raw, &$0) }.orThrow(Error.invalidProfile)
    }

}
