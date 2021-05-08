//
//  DeveloperServicesDevice.swift
//  Supercharge
//
//  Created by Kabir Oberai on 07/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesDevice: Decodable {
    public struct ID: RawRepresentable, Decodable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }

    public let id: ID
    public let name: String
    public let udid: String
    public let platform: DeveloperServicesPlatform
    public let type: String // TODO: Create enum
    public let model: String?

    private enum CodingKeys: String, CodingKey {
        case id = "deviceId"
        case name
        case udid = "deviceNumber"
        case platform = "devicePlatform"
        case type = "deviceClass"
        case model
    }
}
