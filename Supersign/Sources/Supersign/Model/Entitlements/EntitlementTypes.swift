//
//  EntitlementTypes.swift
//  Supercharge
//
//  Created by Kabir Oberai on 29/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import ProtoCodable

// swiftlint:disable type_name

extension EntitlementContainer {
    public static let supportedTypes: [ProtoCodable.Type] = [
        ApplicationIdentifierEntitlement.self,
        TeamIdentifierEntitlement.self,
        KeychainAccessGroupsEntitlement.self,
        GetTaskAllowEntitlement.self,
//        AssociatedDomainsEntitlement.self,
        APSEnvironmentEntitlement.self,
        AppGroupEntitlement.self,
//        NetworkExtensionEntitlement.self,
        MultipathEntitlement.self,
        VPNConfigurationEntitlement.self,
        SiriKitEntitlement.self,
        InterAppAudioEntitlement.self,
        WirelessAccessoryEntitlement.self,
        HomeKitEntitlement.self,
        HealthKitEntitlement.self,
    ]
}

public struct ApplicationIdentifierEntitlement: Entitlement, RawRepresentable {
    public static let identifier = "application-identifier"
    public static let isFree = true

    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct TeamIdentifierEntitlement: Entitlement, RawRepresentable {
    public static let identifier = "com.apple.developer.team-identifier"
    public static let isFree = true

    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct KeychainAccessGroupsEntitlement: Entitlement, RawRepresentable {
    public static let identifier = "keychain-access-groups"
    public static let isFree = true

    public var rawValue: [String]
    public init(rawValue: [String]) { self.rawValue = rawValue }

    // weird bug – the auto-generated implementation treats rawValue like a regular key for some reason
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode([String].self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AppGroupEntitlement: Entitlement, RawRepresentable {
    public static let identifier = "com.apple.security.application-groups"
    // FIXME: Enable app groups on free accounts
    // but first we need to fix the bug where it only assigns one
    // app group even if the ents say there are multiple
    public static let isFree = false

    public var rawValue: [DeveloperServicesAppGroup.GroupID]
    public init(rawValue: [DeveloperServicesAppGroup.GroupID]) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode([DeveloperServicesAppGroup.GroupID].self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct GetTaskAllowEntitlement: Entitlement, RawRepresentable {
    public static let identifier = "get-task-allow"
    public static let isFree = true
    public static let canList = false

    public var rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct AssociatedDomainsEntitlement: Entitlement, RawRepresentable {
    public static let identifier = "com.apple.developer.associated-domains"
    public static let isFree = false

    public var rawValue: [String]
    public init(rawValue: [String]) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode([String].self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum APSEnvironmentEntitlement: String, Entitlement {
    public static let identifier = "aps-environment"
    public static let isFree = false

    case development
    case production
}

public enum DataProtectionEntitlement: String, Entitlement {
    public static let identifier = "com.apple.developer.default-data-protection"
    public static let isFree = true

    case complete = "NSFileProtectionComplete"
    case unlessOpen = "NSFileProtectionCompleteUnlessOpen"
    case untilFirstAuth = "NSFileProtectionCompleteUntilFirstUserAuthentication"
}

public struct NetworkExtensionEntitlement: Entitlement, RawRepresentable {
    public static let identifier = "com.apple.developer.networking.networkextension"
    public static let isFree = false

    public var rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct MultipathEntitlement: Entitlement, RawRepresentable {
    public static let identifier = "com.apple.developer.networking.multipath"
    public static let isFree = false

    public var rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct VPNConfigurationEntitlement: Entitlement, RawRepresentable {
    public static let identifier = "com.apple.networking.vpn.configuration"
    public static let isFree = false

    public var rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct SiriKitEntitlement: Entitlement, RawRepresentable {
    public static let identifier = "com.apple.developer.siri"
    public static let isFree = false

    public var rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct InterAppAudioEntitlement: Entitlement, RawRepresentable {
    public static let identifier = "inter-app-audio"
    public static let isFree = true

    public var rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct WirelessAccessoryEntitlement: Entitlement, RawRepresentable {
    public static let identifier = "com.apple.external-accessory.wireless-configuration"
    public static let isFree = true

    public var rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct HomeKitEntitlement: Entitlement, RawRepresentable {
    public static let identifier = "com.apple.developer.homekit"
    public static let isFree = true

    public var rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct HealthKitEntitlement: Entitlement, RawRepresentable {
    public static let identifier = "com.apple.developer.healthkit"
    public static let isFree = true

    public var rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}
