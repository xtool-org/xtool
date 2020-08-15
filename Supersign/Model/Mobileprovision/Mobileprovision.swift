//
//  Mobileprovision.swift
//  Supercharge
//
//  Created by Kabir Oberai on 07/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public class Mobileprovision: Decodable {

    public enum Error: Swift.Error {
        case invalidProfile
    }

    public struct Digest: Decodable {
        public let name: String
        public let uuid: String
        public let teamIdentifiers: [DeveloperServicesTeam.ID]
        public let creationDate: Date
        public let expirationDate: Date
        public let devices: [String]
        public let certificates: [Certificate]
        public let entitlements: Entitlements

        private enum CodingKeys: String, CodingKey {
            case name = "Name"
            case uuid = "UUID"
            case teamIdentifiers = "TeamIdentifier"
            case creationDate = "CreationDate"
            case expirationDate = "ExpirationDate"
            case devices = "ProvisionedDevices"
            case certificates = "DeveloperCertificates"
            case entitlements = "Entitlements"
        }
    }

    let raw: mobileprovision_t

    private static func mobileprovision(from data: Data) -> mobileprovision_t? {
        data.withUnsafeBytes {
            guard let base = $0.baseAddress else { return nil }
            return mobileprovision_create_from_data(base, $0.count)
        }
    }

    public init(data: Data) throws {
        guard let profile = Self.mobileprovision(from: data) else {
            throw Error.invalidProfile
        }
        self.raw = profile
    }

    public init(contentsOf url: URL) throws {
        guard let profile = url.withUnsafeFileSystemRepresentation({ $0.flatMap(mobileprovision_create_from_path) })
            else { throw Error.invalidProfile }
        self.raw = profile
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        guard let profile = Self.mobileprovision(from: data) else {
            throw Error.invalidProfile
        }
        self.raw = profile
    }

    deinit {
        mobileprovision_free(raw)
    }

    public func digest() throws -> Digest {
        var len = 0
        guard let ptr = mobileprovision_get_digest(raw, &len), len > 0 else {
            throw Error.invalidProfile
        }
        let data = Data(bytes: ptr, count: len)
        return try PropertyListDecoder().decode(Digest.self, from: data)
    }

    public func data() throws -> Data {
        try Data { mobileprovision_get_data(raw, &$0) }.orThrow(Error.invalidProfile)
    }

}
