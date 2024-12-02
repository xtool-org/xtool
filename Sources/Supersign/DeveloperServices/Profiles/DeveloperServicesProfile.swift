//
//  DeveloperServicesProfile.swift
//  Supercharge
//
//  Created by Kabir Oberai on 29/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesProfile: Decodable, Sendable {
    public struct ID: RawRepresentable, Decodable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }

    public let id: ID
    public let name: String
    public let status: String
    public let type: String
    public let platform: DeveloperServicesPlatform
    public let uuid: String
    public let version: String
    public let expiry: Date
    public let appIDID: DeveloperServicesAppID.ID
    public let appID: DeveloperServicesAppID
    public let isFree: Bool
    public let mobileprovision: Mobileprovision?

    private enum CodingKeys: String, CodingKey {
        case id = "provisioningProfileId"
        case name
        case status
        case type
        case platform = "proProPlatform"
        case uuid = "UUID"
        case version
        case expiry = "dateExpire"
        case appIDID = "appIdId"
        case appID = "appId"
        case isFree = "isFreeProvisioningProfile"
        case mobileprovision = "encodedProfile"
    }
}
