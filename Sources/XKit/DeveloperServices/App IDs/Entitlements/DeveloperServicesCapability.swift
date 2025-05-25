//
//  DeveloperServicesFeatureTypes.swift
//  Supercharge
//
//  Created by Kabir Oberai on 29/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import DeveloperAPI

public struct DeveloperServicesCapability: Sendable, Hashable {
    public var capabilityType: Components.Schemas.CapabilityType
    public var isFree: Bool
    public var settings: [Components.Schemas.CapabilitySetting]?

    public init(
        _ capabilityType: Components.Schemas.CapabilityType.Value1Payload,
        isFree: Bool,
        settings: [Components.Schemas.CapabilitySetting]? = nil
    ) {
        self.capabilityType = .init(capabilityType)
        self.isFree = isFree
        self.settings = settings
    }
}

protocol EntitlementWithCapability: Entitlement {
    var capability: DeveloperServicesCapability { get }
}

extension Entitlement {
    var anyCapability: DeveloperServicesCapability? {
        (self as? EntitlementWithCapability)?.capability
    }
}

// MARK: - Special Features

extension DataProtectionEntitlement: EntitlementWithCapability {
    var capability: DeveloperServicesCapability {
        let option: Components.Schemas.CapabilityOption.KeyPayload.Value1Payload = switch self {
        case .complete: .completeProtection
        case .unlessOpen: .protectedUnlessOpen
        case .untilFirstAuth: .protectedUntilFirstUserAuth
        }
        return DeveloperServicesCapability(
            .dataProtection,
            isFree: true,
            settings: [
                .init(
                    key: .init(.dataProtectionPermissionLevel),
                    options: [.init(key: .init(option))]
                )
            ]
        )
    }
}

// MARK: - Boolean Features

// https://github.com/fastlane/fastlane/blob/master/spaceship/lib/spaceship/portal/app_service.rb

extension AppGroupEntitlement: EntitlementWithCapability {
    var capability: DeveloperServicesCapability {
        // FIXME: Enable app groups on free accounts
        // but we need to always assign only one group
        DeveloperServicesCapability(.appGroups, isFree: false)
    }
}

extension AssociatedDomainsEntitlement: EntitlementWithCapability {
    var capability: DeveloperServicesCapability {
        DeveloperServicesCapability(.associatedDomains, isFree: false)
    }
}

extension HealthKitEntitlement: EntitlementWithCapability {
    var capability: DeveloperServicesCapability {
        DeveloperServicesCapability(.healthkit, isFree: true)
    }
}

extension HomeKitEntitlement: EntitlementWithCapability {
    var capability: DeveloperServicesCapability {
        DeveloperServicesCapability(.homekit, isFree: true)
    }
}

extension InterAppAudioEntitlement: EntitlementWithCapability {
    var capability: DeveloperServicesCapability {
        DeveloperServicesCapability(.interAppAudio, isFree: true)
    }
}

extension MultipathEntitlement: EntitlementWithCapability {
    var capability: DeveloperServicesCapability {
        DeveloperServicesCapability(.multipath, isFree: false)
    }
}

extension NetworkExtensionEntitlement: EntitlementWithCapability {
    var capability: DeveloperServicesCapability {
        DeveloperServicesCapability(.networkExtensions, isFree: false)
    }
}

extension VPNConfigurationEntitlement: EntitlementWithCapability {
    public var capability: DeveloperServicesCapability {
        DeveloperServicesCapability(.personalVpn, isFree: false)
    }
}

extension APSEnvironmentEntitlement: EntitlementWithCapability {
    var capability: DeveloperServicesCapability {
        DeveloperServicesCapability(.pushNotifications, isFree: false)
    }
}

extension SiriKitEntitlement: EntitlementWithCapability {
    var capability: DeveloperServicesCapability {
        DeveloperServicesCapability(.sirikit, isFree: false)
    }
}

extension WirelessAccessoryEntitlement: EntitlementWithCapability {
    var capability: DeveloperServicesCapability {
        DeveloperServicesCapability(.wirelessAccessoryConfiguration, isFree: true)
    }
}
