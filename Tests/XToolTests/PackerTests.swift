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

private func product(
    _ type: Plan.ProductType,
    infoPlist: [String: any Sendable] = [:]
) -> Plan.Product {
    Plan.Product(
        type: type,
        product: "Example",
        deploymentTarget: "17.0",
        bundleID: "com.example.Example",
        infoPlist: infoPlist,
        resources: []
    )
}

@Test func appExtensionKeepsMainSymbolDespiteForeignEntryPoint() {
    let flags = product(.appExtension).linkerFlags
    #expect(flags.contains("_NSExtensionMain"))
    // The entry point is Foundation's, so nothing references the extension's own `main`
    // and the dead-strip would drop the whole extension unless it is forced to stay.
    #expect(flags.contains(["-Xlinker", "-u", "-Xlinker", "_main"]))
    // ...and the generated Package.swift snippet actually carries the quoted pair.
    #expect(product(.appExtension).linkerSettings.contains(#""-u", "-Xlinker", "_main""#))
}

@Test func appExtensionWithoutPrincipalClassKeepsMainSymbol() {
    let plist: [String: any Sendable] = ["NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"]]
    let flags = product(.appExtension, infoPlist: plist).linkerFlags
    #expect(flags.contains(["-Xlinker", "-u", "-Xlinker", "_main"]))
}

@Test func appExtensionWithPrincipalClassOmitsMainSymbol() {
    let plist: [String: any Sendable] = ["NSExtension": ["NSExtensionPrincipalClass": "NotificationService"]]
    let flags = product(.appExtension, infoPlist: plist).linkerFlags
    #expect(!flags.contains("-u"))
    #expect(flags.contains(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]))
    #expect(flags.contains("@executable_path/../../Frameworks"))
}

@Test func appExtensionWithMainStoryboardOmitsMainSymbol() {
    let plist: [String: any Sendable] = ["NSExtension": ["NSExtensionMainStoryboard": "MainInterface"]]
    let flags = product(.appExtension, infoPlist: plist).linkerFlags
    #expect(!flags.contains("-u"))
    #expect(flags.contains(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]))
}

@Test func applicationDoesNotForceMainSymbol() {
    #expect(!product(.application).linkerFlags.contains("-u"))
}
