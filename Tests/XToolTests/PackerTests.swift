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
    #expect(info["UIDeviceFamily"] as? [Int] == [1, 2])
    #expect(info["LSRequiresIPhoneOS"] == nil)

    let defaults = Packer.platformInfoPlist([:], type: .appExtension, triple: "arm64-apple-ios")
    #expect(defaults["UIDeviceFamily"] as? [Int] == [1, 2])
}

@Test func platformInfoPlistWidensAppExtensionDeviceFamily() {
    for declared in [[2], [1], [2, 1], [1, 2, 4]] {
        let info = Packer.platformInfoPlist(["UIDeviceFamily": declared], type: .appExtension, triple: "arm64-apple-ios")
        #expect(info["UIDeviceFamily"] as? [Int] == Set(declared).union([1, 2]).sorted())
    }
}

@Test func platformInfoPlistLeavesApplicationDeviceFamilyAlone() {
    let info = Packer.platformInfoPlist(["UIDeviceFamily": [2]], type: .application, triple: "arm64-apple-ios")
    #expect(info["UIDeviceFamily"] as? [Int] == [2])
}

@Test func platformInfoPlistOverridesArm64False() {
    let info = Packer.platformInfoPlist(
        ["UIRequiredDeviceCapabilities": ["arm64": false, "metal": true]],
        type: .application,
        triple: "arm64-apple-ios"
    )
    #expect(info["UIRequiredDeviceCapabilities"] as? [String: Bool] == ["arm64": true, "metal": true])
}

@Test func platformInfoPlistFallsBackOnUnrecognizedCapabilities() {
    for declared: any Sendable in ["metal", [1, 2], 3] {
        let info = Packer.platformInfoPlist(
            ["UIRequiredDeviceCapabilities": declared],
            type: .application,
            triple: "arm64-apple-ios"
        )
        #expect(info["UIRequiredDeviceCapabilities"] as? [String] == ["arm64"])
    }
}
