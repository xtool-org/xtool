import Foundation
import Testing
@testable import XKit

@Test func associatedDomainsEntitlementMapsToDeveloperCapability() throws {
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>com.apple.developer.associated-domains</key>
        <array>
            <string>applinks:example.com</string>
        </array>
    </dict>
    </plist>
    """

    let entitlements = try PropertyListDecoder().decode(
        Entitlements.self,
        from: Data(plist.utf8)
    )
    let associatedDomains = try #require(
        entitlements.entitlements().compactMap { $0 as? AssociatedDomainsEntitlement }.first
    )

    #expect(associatedDomains.rawValue == ["applinks:example.com"])
    #expect(associatedDomains.capability.capabilityType.value1 == .associatedDomains)
    #expect(!associatedDomains.capability.isFree)

    let encoded = try PropertyListEncoder().encode(entitlements)
    let dictionary = try #require(
        PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any]
    )

    #expect(dictionary[AssociatedDomainsEntitlement.identifier] as? [String] == ["applinks:example.com"])
}

@Test func associatedDomainsEntitlementIsRequestedForPaidTeams() throws {
    let entitlements = try Entitlements(entitlements: [
        AssociatedDomainsEntitlement(rawValue: ["applinks:example.com"])
    ])

    let capabilities = try DeveloperServicesAddAppOperation.capabilities(
        for: entitlements,
        isFreeTeam: false
    )

    #expect(capabilities[.init(.associatedDomains)] != nil)
}

@Test func associatedDomainsEntitlementIsFilteredForFreeTeams() throws {
    let entitlements = try Entitlements(entitlements: [
        AssociatedDomainsEntitlement(rawValue: ["applinks:example.com"])
    ])

    let capabilities = try DeveloperServicesAddAppOperation.capabilities(
        for: entitlements,
        isFreeTeam: true
    )

    #expect(capabilities[.init(.associatedDomains)] == nil)
}
