//
//  DeveloperServiceAppGroup.swift
//  Supercharge
//
//  Created by Kabir Oberai on 29/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesAppGroup: Decodable, Sendable {
    public struct ID: RawRepresentable, Decodable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }
    public let id: ID

    public let name: String

    public struct GroupID: RawRepresentable, Hashable, Codable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }
    public let groupID: GroupID

    private enum CodingKeys: String, CodingKey {
        case id = "applicationGroup"
        case name
        case groupID = "identifier"
    }
}
