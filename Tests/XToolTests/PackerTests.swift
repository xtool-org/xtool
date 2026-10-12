import Testing
@testable import PackLib

@Test func cfBundleSupportedPlatformsFollowsBuildTriple() {
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios") == ["iPhoneOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios-simulator") == ["iPhoneSimulator"])

    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0") == ["iPhoneOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0-simulator") == ["iPhoneSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-ios-simulator") == ["iPhoneSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-macosx") == ["MacOSX"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-macosx") == ["MacOSX"])

    #expect(Packer.cfBundleSupportedPlatforms(for: "unknown-triple") == ["iPhoneOS"])
}

@Test func platformInfoPlistKeepsUserCapabilities() {
    let info = Packer.platformInfoPlist(
        ["UIRequiredDeviceCapabilities": ["metal"]],
        type: .application,
        triple: "arm64-apple-ios"
    )
    #expect(info["UIRequiredDeviceCapabilities"] as? [String] == ["arm64", "metal"])
    #expect(info["LSRequiresIPhoneOS"] as? Bool == true)
    #expect(info["CFBundleSupportedPlatforms"] as? [String] == ["iPhoneOS"])
}

@Test func platformInfoPlistDefaultsToArm64() {
    let info = Packer.platformInfoPlist([:], type: .application, triple: "arm64-apple-ios")
    #expect(info["UIRequiredDeviceCapabilities"] as? [String] == ["arm64"])
}

@Test func platformInfoPlistDoesNotDuplicateArm64() {
    let info = Packer.platformInfoPlist(
        ["UIRequiredDeviceCapabilities": ["arm64", "metal"]],
        type: .application,
        triple: "arm64-apple-ios"
    )
    #expect(info["UIRequiredDeviceCapabilities"] as? [String] == ["arm64", "metal"])
}

@Test func platformInfoPlistMergesDictionaryCapabilities() {
    let info = Packer.platformInfoPlist(
        ["UIRequiredDeviceCapabilities": ["metal": true]],
        type: .application,
        triple: "arm64-apple-ios"
    )
    #expect(info["UIRequiredDeviceCapabilities"] as? [String: Bool] == ["metal": true, "arm64": true])
}

@Test func platformInfoPlistCoversAppExtensions() {
    let info = Packer.platformInfoPlist(
        ["UIRequiredDeviceCapabilities": ["metal"], "UIDeviceFamily": [1]],
        type: .appExtension,
        triple: "arm64-apple-ios-simulator"
    )
    #expect(info["CFBundleSupportedPlatforms"] as? [String] == ["iPhoneSimulator"])
    #expect(info["UIRequiredDeviceCapabilities"] as? [String] == ["arm64", "metal"])
    #expect(info["UIDeviceFamily"] as? [Int] == [1])
    #expect(info["LSRequiresIPhoneOS"] == nil)

    let defaults = Packer.platformInfoPlist([:], type: .appExtension, triple: "arm64-apple-ios")
    #expect(defaults["UIDeviceFamily"] as? [Int] == [1, 2])
}
