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

@Test func extensionStubAnchorsMainAgainstDeadStripping() {
    #expect(Packer.stubSource(for: .application) == "")

    let stub = Packer.stubSource(for: .appExtension)
    // Extensions link with `-e _NSExtensionMain`, so nothing references
    // the product's `main`; `-dead_strip` then strips all of its code.
    // The stub must weakly anchor `main` without requiring it to exist.
    #expect(stub.contains("weak_import"))
    #expect(stub.contains("&main"))
    #expect(stub.contains("used"))
}
