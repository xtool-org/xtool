import Foundation
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

private func makeProduct(type: Plan.ProductType) -> Plan.Product {
    Plan.Product(
        type: type,
        product: "Demo",
        deploymentTarget: "17.0",
        bundleID: "com.example.demo",
        infoPlist: [:],
        resources: []
    )
}

@Test func sysrootLinkerFlagsPassIsysrootToClang() {
    let sdk = URL(fileURLWithPath: "/sdks/iPhoneOS27.1.sdk")
    #expect(Packer.sysrootLinkerFlags(sdkRoot: sdk) == [
        "-Xclang-linker", "-isysroot", "-Xclang-linker", "/sdks/iPhoneOS27.1.sdk",
    ])
    #expect(Packer.sysrootLinkerFlags(sdkRoot: nil).isEmpty)
}

@Test(arguments: [Plan.ProductType.application, .appExtension])
func generatedLinkerSettingsIncludeSysroot(type: Plan.ProductType) {
    let flags = Packer.sysrootLinkerFlags(sdkRoot: URL(fileURLWithPath: "/sdks/with \"quote\"/iPhoneOS27.1.sdk"))
    let settings = makeProduct(type: type).linkerSettings(extraFlags: flags)
    #expect(settings.contains("\"-Xclang-linker\","))
    #expect(settings.contains("\"-isysroot\","))
    #expect(settings.contains(#""/sdks/with \"quote\"/iPhoneOS27.1.sdk","#))
    #expect(settings.contains("@executable_path/Frameworks"))

    #expect(!makeProduct(type: type).linkerSettings(extraFlags: []).contains("isysroot"))
}

@Test func sdkRootFollowsTheTripleAndPicksVersionedSDK() throws {
    let bundle = FileManager.default.temporaryDirectory
        .appendingPathComponent("SysrootTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: bundle) }
    let sdks = [
        "iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk",
        "iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.1.sdk",
    ]
    for sdk in sdks {
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Developer/Platforms/\(sdk)"),
            withIntermediateDirectories: true
        )
    }
    try Data("epoch=4\n".utf8).write(to: bundle.appendingPathComponent("darwin-sdk-version.txt"))
    let sdk = try #require(DarwinSDK(bundle: bundle))

    #expect(sdk.sdkRoot(forTriple: "arm64-apple-ios")?.lastPathComponent == "iPhoneOS27.1.sdk")
    #expect(sdk.sdkRoot(forTriple: "arm64-apple-ios17.0-simulator")?.lastPathComponent == "iPhoneSimulator27.1.sdk")
    #expect(sdk.sdkRoot(forTriple: "arm64-apple-macosx") == nil)
}
