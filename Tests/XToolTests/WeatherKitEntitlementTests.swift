import Foundation
import Testing
@testable import XKit

@Test(arguments: [true, false])
func weatherKitEntitlementRoundTrips(enabled: Bool) throws {
    let plist = try PropertyListSerialization.data(
        fromPropertyList: ["com.apple.developer.weatherkit": enabled],
        format: .xml,
        options: 0
    )
    let entitlements = try PropertyListDecoder().decode(Entitlements.self, from: plist)
    let weatherKit = try #require(
        entitlements.entitlements().compactMap { $0 as? WeatherKitEntitlement }.first
    )
    #expect(weatherKit.rawValue == enabled)

    // Rebuild from the typed entitlement to exercise its encoder, rather than the preserved input dictionary.
    let rebuilt = try Entitlements(entitlements: [weatherKit])
    let encoded = try PropertyListEncoder().encode(rebuilt)
    let dictionary = try #require(
        PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any]
    )
    #expect(dictionary["com.apple.developer.weatherkit"] as? Bool == enabled)
    #expect(dictionary.count == 1)
}

@Test func weatherKitEntitlementMapsToDeveloperCapability() throws {
    let entitlements = try Entitlements(entitlements: [WeatherKitEntitlement(rawValue: true)])
    let capabilities = try entitlements.entitlements().compactMap(\.anyCapability)
    #expect(capabilities.count == 1)
    let capability = try #require(capabilities.first)

    #expect(capability.capabilityType.value1 == nil)
    #expect(capability.capabilityType.value2 == "WEATHERKIT")
    #expect(capability.settings == nil)
    #expect(!capability.isFree)

    let encoded = try JSONEncoder().encode(capability.capabilityType)
    #expect(String(decoding: encoded, as: UTF8.self) == "\"WEATHERKIT\"")
}

@Test func weatherKitEntitlementIsFilteredForFreeTeams() throws {
    let entitlements = try Entitlements(entitlements: [
        WeatherKitEntitlement(rawValue: true),
        HomeKitEntitlement(rawValue: true),
    ])
    // Match the filtering performed by DeveloperServicesAddAppOperation.
    let filtered = try entitlements.entitlements().filter { $0.anyCapability?.isFree != false }
    let encoded = try PropertyListEncoder().encode(Entitlements(entitlements: filtered))
    let dictionary = try #require(
        PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any]
    )
    #expect(dictionary["com.apple.developer.weatherkit"] == nil)
    #expect(dictionary["com.apple.developer.homekit"] as? Bool == true)
}
