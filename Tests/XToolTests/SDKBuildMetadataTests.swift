import Foundation
import Testing
@testable import PackLib

@Test(arguments: ["json", "plist"])
func buildMetadataUsesRecordedSDKAndXcodeVersions(format: String) throws {
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataTests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: bundle) }
    let platformPath = "Developer/Platforms/iPhoneOS.platform"
    let sdkPath = "\(platformPath)/Developer/SDKs/iPhoneOS27.1.sdk"
    let sdk = bundle.appendingPathComponent(sdkPath, isDirectory: true)
    try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
    try Data("test".utf8).write(to: bundle.appendingPathComponent("darwin-sdk-version.txt"))
    try JSONSerialization.data(withJSONObject: [
        "targetTriples": ["arm64-apple-ios": ["sdkRootPath": sdkPath]],
    ]).write(to: bundle.appendingPathComponent("swift-sdk.json"))
    let settings: [String: Any] = [
        "CanonicalName": "iphoneos27.1", "Version": "27.1",
        "DefaultProperties": ["DEFAULT_COMPILER": "Compiler-Actual-ID"],
        "SupportedTargets": ["iphoneos": ["MinimumDeploymentTarget": "15.0"]],
    ]
    let settingsData = try format == "json"
        ? JSONSerialization.data(withJSONObject: settings)
        : PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)
    try settingsData.write(to: sdk.appendingPathComponent("SDKSettings.\(format)"))
    let system = sdk.appendingPathComponent("System/Library/CoreServices", isDirectory: true)
    try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["ProductBuildVersion": "SDK-Actual-Build"], format: .binary, options: 0)
        .write(to: system.appendingPathComponent("SystemVersion.plist"))
    let info = ["AdditionalInfo": [
        "DTPlatformName": "iphoneos", "DTPlatformBuild": "$(PLATFORM_PRODUCT_BUILD_VERSION)",
        "DTCompiler": "$(GCC_VERSION)", "DTSDKBuild": "$(SDK_PRODUCT_BUILD_VERSION)",
    ]]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: bundle.appendingPathComponent("\(platformPath)/Info.plist"))
    try PropertyListSerialization.data(fromPropertyList: [
        "CFBundleShortVersionString": "27.1.2", "ProductBuildVersion": "Xcode-Actual-Build",
    ], format: .xml, options: 0).write(to: bundle.appendingPathComponent("xcode-version.plist"))

    let darwinSDK = try #require(DarwinSDK(bundle: bundle))
    let metadata = try darwinSDK.buildMetadata(for: "arm64-apple-ios")
    #expect(try darwinSDK.sdkVersion(for: "arm64-apple-ios") == "27.1")
    #expect(try darwinSDK.minimumDeploymentTarget(for: "arm64-apple-ios") == "15.0")
    #expect(metadata == [
        "DTSDKName": "iphoneos27.1", "DTSDKBuild": "SDK-Actual-Build",
        "DTPlatformName": "iphoneos", "DTPlatformVersion": "27.1", "DTPlatformBuild": "SDK-Actual-Build",
        "DTXcode": "2712", "DTXcodeBuild": "Xcode-Actual-Build", "DTCompiler": "Compiler-Actual-ID",
    ])
    try FileManager.default.removeItem(at: bundle.appendingPathComponent("xcode-version.plist"))
    #expect(throws: (any Error).self) { try darwinSDK.buildMetadata(for: "arm64-apple-ios") }
}

@Test func sdkVersionUsesCatalystVersionMap() throws {
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("SDKVersionTests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: bundle) }
    let root = bundle.appendingPathComponent("SDK", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("test".utf8).write(to: bundle.appendingPathComponent("darwin-sdk-version.txt"))
    try JSONSerialization.data(withJSONObject: [
        "targetTriples": ["arm64-apple-ios-macabi": ["sdkRootPath": "SDK"]],
    ]).write(to: bundle.appendingPathComponent("swift-sdk.json"))
    try JSONSerialization.data(withJSONObject: [
        "Version": "15.0", "VersionMap": ["macOS_iOSMac": ["15.0": "18.0"], "iOSMac_macOS": ["18.0": "15.0"]],
        "SupportedTargets": ["iosmac": ["MinimumDeploymentTarget": "15.0"]],
    ]).write(to: root.appendingPathComponent("SDKSettings.json"))
    let sdk = try #require(DarwinSDK(bundle: bundle))
    #expect(try sdk.sdkVersion(for: "arm64-apple-ios-macabi") == "18.0")
    #expect(try sdk.macOSMinimum(forCatalyst: "18.0", triple: "arm64-apple-ios-macabi") == "15.0")
    // Native macOS reads the selected Xcode SDK without installing a Darwin artifact bundle.
    try FileManager.default.removeItem(at: bundle.appendingPathComponent("swift-sdk.json"))
    #expect(try DarwinSDK.macOSMinimum(forCatalyst: "18.0", sdkRoot: root) == "15.0")
    #expect(try DarwinSDK.minimumDeploymentTarget(for: "arm64-apple-ios-macabi", sdkRoot: root) == "15.0")
}

@Test func xcodeBuildVersionConvertsRecordedVersion() throws {
    #expect(try DarwinSDK.xcodeBuildVersion("16.4") == "1640")
    #expect(try DarwinSDK.xcodeBuildVersion("27.1.2") == "2712")
    #expect(throws: StringError.self) { try DarwinSDK.xcodeBuildVersion("unknown") }
}
