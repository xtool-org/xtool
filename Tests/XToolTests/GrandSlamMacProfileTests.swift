import Foundation
import Testing
@testable import XKit

@Test func grandSlamClientInfoUsesProviderByDefault() throws {
    let serverInfo = "<MacBookPro13,3> <Mac OS X;10.12.6;16G29> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"

    #expect(try OmnisetteADIProvider.resolvedClientInfo(serverInfo, profile: nil) == serverInfo)
    #expect(try OmnisetteADIProvider.resolvedClientInfo(serverInfo, profile: "") == serverInfo)
    #expect(try OmnisetteADIProvider.resolvedClientInfo(serverInfo, profile: "provider") == serverInfo)
}

@Test func grandSlamModernClientInfoOverridesOnlyWhenSelected() throws {
    let serverInfo = "<MacBookPro13,3> <Mac OS X;10.12.6;16G29> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"

    let modernInfo = try OmnisetteADIProvider.resolvedClientInfo(serverInfo, profile: "modern")

    #expect(modernInfo == OmnisetteADIProvider.modernMacClientInfo)
    #expect(modernInfo.contains("<Mac17,3> <macOS;27.0;26A5416b>"))
    #expect(modernInfo.contains("com.apple.akd/1.0"))
    #expect(!modernInfo.contains("com.apple.dt.Xcode"))
}

@Test func grandSlamClientInfoRejectsUnknownProfiles() {
    #expect(throws: OmnisetteADIProvider.ClientInfoProfileError.self) {
        _ = try OmnisetteADIProvider.resolvedClientInfo("server", profile: "unknown")
    }
}

@Test func grandSlamProfileChoicePersistsAndEnvironmentTakesPrecedence() {
    #expect(OmnisetteADIProvider.selectedProfileName(environment: nil, stored: nil) == nil)
    #expect(OmnisetteADIProvider.selectedProfileName(environment: nil, stored: "modern") == "modern")
    #expect(OmnisetteADIProvider.selectedProfileName(environment: "provider", stored: "modern") == "provider")
    #expect(OmnisetteADIProvider.selectedProfileName(environment: "", stored: "modern") == "modern")
}

@Test func grandSlamMacProfilePreferenceStorageIsIndependentOfProvisioning() throws {
    let storage = MemoryKeyValueStorage()
    let provisioningData = Data("existing-provisioning".utf8)

    try storage.setData(provisioningData, forKey: "XTLProvisioningInfo")
    try storage.setString(GrandSlamMacProfile.modern.rawValue, forKey: GrandSlamMacProfile.storageKey)

    #expect(try storage.string(forKey: GrandSlamMacProfile.storageKey) == "modern")
    #expect(try storage.data(forKey: "XTLProvisioningInfo") == provisioningData)
}
