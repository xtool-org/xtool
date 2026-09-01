import Foundation
import Testing
@testable import XKit

@Test func wifiAwareEntitlementMapsToDeveloperCapability() throws {
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>com.apple.developer.wifi-aware</key>
        <array>
            <string>Publish</string>
            <string>Subscribe</string>
        </array>
    </dict>
    </plist>
    """

    let entitlements = try PropertyListDecoder().decode(
        Entitlements.self,
        from: Data(plist.utf8)
    )
    let wifiAware = try #require(
        entitlements.entitlements().compactMap { $0 as? WiFiAwareEntitlement }.first
    )

    #expect(wifiAware.rawValue == ["Publish", "Subscribe"])
    #expect(wifiAware.capability.capabilityType.value1 == nil)
    #expect(wifiAware.capability.capabilityType.value2 == "WIFI_AWARE")
    #expect(wifiAware.capability.settings == nil)
    #expect(!wifiAware.capability.isFree)

    let encoded = try PropertyListEncoder().encode(entitlements)
    let dictionary = try #require(
        PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any]
    )
    #expect(dictionary[WiFiAwareEntitlement.identifier] as? [String] == ["Publish", "Subscribe"])
}
