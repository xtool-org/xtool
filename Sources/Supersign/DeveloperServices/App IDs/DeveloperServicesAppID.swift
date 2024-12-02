//
//  DeveloperServiceAppID.swift
//  Supercharge
//
//  Created by Kabir Oberai on 29/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import ProtoCodable

public struct DeveloperServicesAppID: Decodable, Sendable {
    public struct ID: RawRepresentable, Decodable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }

    public let id: ID
    public let name: String
    public let platform: DeveloperServicesPlatform
    public let bundleID: String
    public let isWildCard: Bool

    private let _features: DeveloperServicesFeatures
    public var features: [DeveloperServicesFeature] { return _features.values }

    private let _enabledFeatures: [String]?
    public var enabledFeatures: [DeveloperServicesFeature.Type] {
        guard let enabledFeatures = _enabledFeatures else { return [] }
        return enabledFeatures.compactMap { identifier in
            let type = ProtoCodableIdentifierMapper.shared.type(
                for: identifier, in: DeveloperServicesFeatureContainer.self
            )
            return type as? DeveloperServicesFeature.Type
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id = "appIdId"
        case name
        case platform = "appIdPlatform"
        case bundleID = "identifier"
        case isWildCard
        case _features = "features"
        case _enabledFeatures = "enabledFeatures"
    }
}
