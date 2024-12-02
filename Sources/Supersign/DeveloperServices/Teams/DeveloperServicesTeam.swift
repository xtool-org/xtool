//
//  DeveloperServicesTeam.swift
//  Supercharge
//
//  Created by Kabir Oberai on 29/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesTeam: Decodable, Sendable {
    public struct ID: RawRepresentable, Decodable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }

    public let id: ID
    public let status: String
    public let name: String

    public struct Membership: Decodable, Sendable {
        public let name: String
        public let platform: DeveloperServicesPlatform
    }
    public let memberships: [Membership]

    public var isFree: Bool {
        !memberships.contains { $0.platform == .iOS && $0.name.contains("Apple Developer Program") }
    }

    private enum CodingKeys: String, CodingKey {
        case id = "teamId"
        case status
        case name
        case memberships
    }
}
