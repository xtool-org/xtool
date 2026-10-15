import Foundation
import Testing
@testable import PackLib
@testable import XToolSupport

@Test(arguments: ["arm64_32-apple-watchos", "arm64-apple-watchos10.0", "x86_64-apple-watchos-simulator"])
func watchPlatformRecognizesTriples(triple: String) {
    #expect(AppPlatform(triple: triple) == .watchOS)
}

@Test func watchBundleUsesWatchMetadata() {
    let info = AppPlatform.watchOS.appInfoPlist()
    #expect(info["UIDeviceFamily"] as? [Int] == [4])
    #expect(info["WKApplication"] as? Bool == true)
    #expect(info["WKWatchOnly"] as? Bool == true)
    #expect(info["WKRunsIndependentlyOfCompanionApp"] == nil)
    #expect(info["UILaunchScreen"] == nil)
    #expect(info["UISupportedInterfaceOrientations"] == nil)
    #expect(AppPlatform.iOS.appInfoPlist()["UIDeviceFamily"] as? [Int] == [1, 2])
}

@Test func watchSchemaSelectsWatchSDKWithoutChangingIOSDefault() throws {
    let schema = try PackSchema(validating: .init(version: .v1, orgID: "com.example", platform: .watchOS))
    #expect(schema.defaultTriple == "arm64_32-apple-watchos")
    #expect(PackSchema.default.defaultTriple == "arm64-apple-ios")
    #expect(AppPlatform.watchOS.sdkName(simulator: false) == "WatchOS")
    #expect(AppPlatform.watchOS.sdkName(simulator: true) == "WatchSimulator")
}

@Test(arguments: ["WatchOS", "WatchSimulator"])
func watchSDKFilesSurviveSlimExtraction(platform: String) {
    let prefix = "Contents/Developer/Platforms/\(platform).platform"
    for suffix in ["Info.plist", "Developer/SDKs/\(platform).sdk/usr/lib/libSystem.tbd", "Developer/usr/lib/swift"] {
        #expect(SDKEntry.wanted.matches("\(prefix)/\(suffix)".split(separator: "/")[...]))
    }
    #expect(!SDKEntry.wanted.matches("\(prefix)/Developer/Applications/Simulator.app".split(separator: "/")[...]))
}

@Test func watchPlistSupportedPlatformsFollowDestination() {
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64_32-apple-watchos10.0") == ["WatchOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-watchos") == ["WatchOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-watchos10.0-simulator") == ["WatchSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-watchos-simulator") == ["WatchSimulator"])
}
