import Testing
@testable import XKit

@Test func signingContextKeepsIOSDefaults() {
    let context = SigningContext(auth: .appStoreConnect(.init(id: "TEST", issuerID: "TEST-ISSUER", pem: "unused")))
    #expect(context.platform == .iOS)
    #expect(!context.preserveBundleID)
}

@Test func tvOSUsesTVDevelopmentProfilesAndAppGroups() {
    #expect(SigningPlatform.tvOS.developmentProfileType.rawValue == "TVOS_APP_DEVELOPMENT")
    #expect(SigningPlatform.tvOS.developerServicesPlatform == .tvOS)
    #expect(SigningPlatform.iOS.developmentProfileType.rawValue == "IOS_APP_DEVELOPMENT")
    #expect(SigningPlatform.iOS.developerServicesPlatform == .iOS)
}

@Test func tvOSSelectsAppleTVDevicesOnly() {
    #expect(SigningPlatform.tvOS.supports(deviceClass: .appleTv))
    #expect(!SigningPlatform.tvOS.supports(deviceClass: .iphone))
    #expect(!SigningPlatform.tvOS.supports(deviceClass: .ipad))
    #expect(!SigningPlatform.tvOS.supports(deviceClass: .ipod))
    #expect(!SigningPlatform.tvOS.supports(deviceClass: .mac))
    #expect(!SigningPlatform.iOS.supports(deviceClass: .appleTv))
    #expect(SigningPlatform.iOS.supports(deviceClass: .iphone))
    #expect(SigningPlatform.iOS.supports(deviceClass: .ipad))
    #expect(SigningPlatform.iOS.supports(deviceClass: .ipod))
}
