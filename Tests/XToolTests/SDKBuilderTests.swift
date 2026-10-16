import Testing
@testable import XToolSupport

@Test func sdkDefinitionUsesPlatformSDKs() throws {
    let definition = SDKBuilder.sdkDefinition(sdks: [
        "iPhoneOS": "iPhoneOS26.0.sdk",
        "MacOSX": "MacOSX26.0.sdk",
        "AppleTVOS": "AppleTVOS26.0.sdk",
        "AppleTVSimulator": "AppleTVSimulator26.0.sdk",
    ])
    let catalyst = try #require(definition.targetTriples["arm64-apple-ios-macabi"])
    #expect(catalyst.sdkRootPath == "Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.0.sdk")
    #expect(catalyst.includeSearchPaths.contains("\(catalyst.sdkRootPath)/System/iOSSupport/usr/include"))
    #expect(catalyst.librarySearchPaths.contains("\(catalyst.sdkRootPath)/System/iOSSupport/usr/lib"))
    let tvOS = try #require(definition.targetTriples["arm64-apple-tvos"])
    #expect(tvOS.sdkRootPath == "Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS26.0.sdk")
    let tvSimulator = try #require(definition.targetTriples["x86_64-apple-tvos-simulator"])
    #expect(tvSimulator.sdkRootPath
        == "Developer/Platforms/AppleTVSimulator.platform/Developer/SDKs/AppleTVSimulator26.0.sdk")
    #expect(tvOS.librarySearchPaths == ["Developer/Platforms/AppleTVOS.platform/Developer/usr/lib"])
    #expect(definition.targetTriples["arm64-apple-ios-simulator"] == nil)
}

@Test func sdkDefinitionOmitsUnavailableTVSDKs() {
    let definition = SDKBuilder.sdkDefinition(sdks: ["iPhoneOS": "iPhoneOS26.0.sdk"])
    #expect(definition.targetTriples["arm64-apple-ios"] != nil)
    #expect(definition.targetTriples["arm64-apple-tvos"] == nil)
    #expect(definition.targetTriples["arm64-apple-tvos-simulator"] == nil)
    #expect(definition.targetTriples["arm64-apple-ios-macabi"] == nil)
}

@Test func sdkExtractionRetainsTVSDKs() {
    let device = "Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS26.0.sdk/usr/lib/libc.tbd"
    let simulator = "Contents/Developer/Platforms/AppleTVSimulator.platform/Developer/usr/lib/swift/libswiftTesting.dylib"
    let watch = "Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS26.0.sdk/usr/lib/libc.tbd"
    #expect(SDKEntry.wanted.matches(device.split(separator: "/")[...]))
    #expect(SDKEntry.wanted.matches(simulator.split(separator: "/")[...]))
    #expect(!SDKEntry.wanted.matches(watch.split(separator: "/")[...]))
    #expect(SDKEntry.wanted.matches("Contents/version.plist".split(separator: "/")[...]))
}
