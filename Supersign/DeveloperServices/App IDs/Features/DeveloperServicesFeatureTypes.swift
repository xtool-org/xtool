//
//  DeveloperServicesFeatureTypes.swift
//  Supercharge
//
//  Created by Kabir Oberai on 29/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import ProtoCodable

// swiftlint:disable type_name

extension DeveloperServicesFeatureContainer {
    static let supportedTypes: [ProtoCodable.Type] = [
        DeveloperServicesCloudKitFeature.self,
        DeveloperServicesDataProtectionFeature.self,
        DeveloperServicesAccessWifiFeature.self,
        DeveloperServicesAppGroupFeature.self,
        DeveloperServicesApplePayFeature.self,
        DeveloperServicesAssociatedDomainsFeature.self,
        DeveloperServicesClassKitFeature.self,
        DeveloperServicesAutoFillCredentialFeature.self,
        DeveloperServicesGameCenterFeature.self,
        DeveloperServicesHealthKitFeature.self,
        DeveloperServicesHomeKitFeature.self,
        DeveloperServicesHotspotFeature.self,
        DeveloperServicesCloudFeature.self,
        DeveloperServicesInAppPurchaseFeature.self,
        DeveloperServicesInterAppAudioFeature.self,
        DeveloperServicesMultipathFeature.self,
        DeveloperServicesNetworkExtensionFeature.self,
        DeveloperServicesNFCTagReadingFeature.self,
        DeveloperServicesPersonalVPNFeature.self,
        DeveloperServicesPassbookFeature.self,
        DeveloperServicesPushNotificationFeature.self,
        DeveloperServicesSiriKitFeature.self,
        DeveloperServicesVPNConfigurationFeature.self,
        DeveloperServicesWalletFeature.self,
        DeveloperServicesWirelessAccessoryFeature.self,
    ]
}

// MARK: - Special Features

public enum DeveloperServicesCloudKitFeature: Int, DeveloperServicesFeature {
    public static let identifier = "cloudKitVersion"

    case xcode5Compatible = 1
    case cloudKit = 2
}

public enum DeveloperServicesDataProtectionFeature: String, DeveloperServicesFeature {
    public static let identifier = "dataProtection"

    case off = ""
    case complete
    case unlessOpen = "unlessopen"
    case untilFirstAuth = "untilfirstauth"
}
extension DataProtectionEntitlement: EntitlementWithFeature {
    func typedFeature() -> DeveloperServicesDataProtectionFeature {
        switch self {
        case .complete: return .complete
        case .unlessOpen: return .unlessOpen
        case .untilFirstAuth: return .untilFirstAuth
        }
    }
}

// MARK: - Boolean Features

// https://github.com/fastlane/fastlane/blob/master/spaceship/lib/spaceship/portal/app_service.rb

public struct DeveloperServicesAccessWifiFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "AWEQ28MY3E"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct DeveloperServicesAppGroupFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "APG3427HIY"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}
extension AppGroupEntitlement: EntitlementWithFeature {
    func typedFeature() -> DeveloperServicesAppGroupFeature {
        .init(rawValue: !rawValue.isEmpty)
    }
}

public struct DeveloperServicesApplePayFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "OM633U5T5G"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct DeveloperServicesAssociatedDomainsFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "SKC3T5S89Y"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}
extension AssociatedDomainsEntitlement: EntitlementWithFeature {
    func typedFeature() -> DeveloperServicesAssociatedDomainsFeature {
        .init(rawValue: true)
    }
}

public struct DeveloperServicesClassKitFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "PKTJAN2017"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct DeveloperServicesAutoFillCredentialFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "CPEQ28MX4E"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct DeveloperServicesGameCenterFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "gameCenter"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct DeveloperServicesHealthKitFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "HK421J6T7P"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}
extension HealthKitEntitlement: EntitlementWithFeature {
    typealias Feature = DeveloperServicesHealthKitFeature
}

public struct DeveloperServicesHomeKitFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "homeKit"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}
extension HomeKitEntitlement: EntitlementWithFeature {
    typealias Feature = DeveloperServicesHomeKitFeature
}

public struct DeveloperServicesHotspotFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "HSC639VEI8"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct DeveloperServicesCloudFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "iCloud"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct DeveloperServicesInAppPurchaseFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "inAppPurchase"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct DeveloperServicesInterAppAudioFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "IAD53UNK2F"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}
extension InterAppAudioEntitlement: EntitlementWithFeature {
    typealias Feature = DeveloperServicesInterAppAudioFeature
}

public struct DeveloperServicesMultipathFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "MP49FN762P"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}
extension MultipathEntitlement: EntitlementWithFeature {
    typealias Feature = DeveloperServicesMultipathFeature
}

public struct DeveloperServicesNetworkExtensionFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "NWEXT04537"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}
extension NetworkExtensionEntitlement: EntitlementWithFeature {
    typealias Feature = DeveloperServicesNetworkExtensionFeature
}

public struct DeveloperServicesNFCTagReadingFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "NFCTRMAY17"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct DeveloperServicesPersonalVPNFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "V66P55NK2I"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct DeveloperServicesPassbookFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "passbook"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct DeveloperServicesPushNotificationFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "push"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}
extension APSEnvironmentEntitlement: EntitlementWithFeature {
    func typedFeature() -> DeveloperServicesPushNotificationFeature {
        .init(rawValue: true)
    }
}

public struct DeveloperServicesSiriKitFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "SI015DKUHP"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}
extension SiriKitEntitlement: EntitlementWithFeature {
    typealias Feature = DeveloperServicesSiriKitFeature
}

public struct DeveloperServicesVPNConfigurationFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "V66P55NK2I"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}
extension VPNConfigurationEntitlement: EntitlementWithFeature {
    typealias Feature = DeveloperServicesVPNConfigurationFeature
}

public struct DeveloperServicesWalletFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "pass"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}

public struct DeveloperServicesWirelessAccessoryFeature: DeveloperServicesFeature, RawRepresentable {
    public static let identifier = "WC421J6T7P"

    public let rawValue: Bool
    public init(rawValue: Bool) { self.rawValue = rawValue }
}
extension WirelessAccessoryEntitlement: EntitlementWithFeature {
    typealias Feature = DeveloperServicesWirelessAccessoryFeature
}
