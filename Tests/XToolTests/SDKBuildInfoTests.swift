import Foundation
import Testing
@testable import PackLib

/// A minimal Xcode.app tree holding only the files that the `DT*` values come from.
private struct FakeXcode {
    let root: URL
    var contents: URL { root.appendingPathComponent("Contents") }
    var developer: URL { contents.appendingPathComponent("Developer") }

    init(
        xcodeVersion: String = "26.5",
        xcodeBuild: String = "17F42",
        platformBuild: String? = "23F73",
        sdkVersion: String = "26.5",
        sdkBuild: String = "23F73"
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SDKBuildInfoTests-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default

        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        try Self.writePlist(
            ["CFBundleShortVersionString": xcodeVersion, "ProductBuildVersion": xcodeBuild],
            to: contents.appendingPathComponent("version.plist")
        )

        let platform = developer.appendingPathComponent("Platforms/iPhoneOS.platform")
        let sdk = platform.appendingPathComponent("Developer/SDKs/iPhoneOS\(sdkVersion).sdk")
        let coreServices = sdk.appendingPathComponent("System/Library/CoreServices")
        try fm.createDirectory(at: coreServices, withIntermediateDirectories: true)
        if let platformBuild {
            try Self.writePlist(
                ["ProductBuildVersion": platformBuild],
                to: platform.appendingPathComponent("version.plist")
            )
        }
        try Self.writePlist(
            ["ProductBuildVersion": sdkBuild],
            to: coreServices.appendingPathComponent("SystemVersion.plist")
        )
        try Data("""
        {"Version": "\(sdkVersion)", "CanonicalName": "iphoneos\(sdkVersion)"}
        """.utf8).write(to: sdk.appendingPathComponent("SDKSettings.json"))
        // the unversioned symlink Xcode ships next to the real directory
        try fm.createSymbolicLink(
            atPath: sdk.deletingLastPathComponent().appendingPathComponent("iPhoneOS.sdk").path,
            withDestinationPath: "iPhoneOS\(sdkVersion).sdk"
        )
    }

    private static func writePlist(_ plist: [String: String], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    func collect() -> SDKBuildInfo {
        SDKBuildInfo.collect(xcodeContents: contents, developer: developer)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private let xcode26_5 = SDKBuildInfo(
    xcodeVersion: "26.5",
    xcodeBuild: "17F42",
    platformBuild: "23F73",
    platformVersion: "26.5",
    sdkName: "iphoneos26.5",
    sdkBuild: "23F73"
)

@Test func collectReadsBuildInfoFromXcodeTree() throws {
    let xcode = try FakeXcode()
    defer { xcode.cleanUp() }
    #expect(xcode.collect() == xcode26_5)
    #expect(xcode.collect().missingFields.isEmpty)
}

@Test func collectToleratesMissingFiles() throws {
    let xcode = try FakeXcode(platformBuild: nil)
    defer { xcode.cleanUp() }
    try FileManager.default.removeItem(at: xcode.contents.appendingPathComponent("version.plist"))

    let info = xcode.collect()
    #expect(info.xcodeVersion == nil)
    #expect(info.platformBuild == nil)
    #expect(info.sdkBuild == "23F73")
    #expect(info.missingFields == ["xcodeVersion", "xcodeBuild"])
}

@Test func xcodeCodeFollowsDTXcodeEncoding() {
    #expect(SDKBuildInfo.xcodeCode(forVersion: "26.5") == "2650")
    #expect(SDKBuildInfo.xcodeCode(forVersion: "26.5.0") == "2650")
    #expect(SDKBuildInfo.xcodeCode(forVersion: "26.0.1") == "2601")
    #expect(SDKBuildInfo.xcodeCode(forVersion: "9.4.1") == "0941")
    #expect(SDKBuildInfo.xcodeCode(forVersion: "26") == "2600")
    #expect(SDKBuildInfo.xcodeCode(forVersion: "") == nil)
    #expect(SDKBuildInfo.xcodeCode(forVersion: "26.beta") == nil)
    #expect(SDKBuildInfo.xcodeCode(forVersion: "26.5.1.2") == nil)
}

@Test func infoPlistKeysMatchXcodeReferenceIPA() {
    #expect(xcode26_5.infoPlistKeys() == [
        "DTCompiler": "com.apple.compilers.llvm.clang.1_0",
        "DTPlatformBuild": "23F73",
        "DTPlatformName": "iphoneos",
        "DTPlatformVersion": "26.5",
        "DTSDKBuild": "23F73",
        "DTSDKName": "iphoneos26.5",
        "DTXcode": "2650",
        "DTXcodeBuild": "17F42",
    ])
}

@Test func platformBuildFallsBackToSDKBuild() {
    var info = xcode26_5
    info.platformBuild = nil
    #expect(info.infoPlistKeys()["DTPlatformBuild"] == "23F73")
}

@Test func buildMachineOSBuildIsOptIn() {
    #expect(xcode26_5.infoPlistKeys()["BuildMachineOSBuild"] == nil)
    #expect(xcode26_5.infoPlistKeys(buildMachineOSBuild: "25G83")["BuildMachineOSBuild"] == "25G83")

    #expect(Packer.buildMachineOSBuild(environment: [:]) == nil)
    #expect(Packer.buildMachineOSBuild(environment: [Packer.buildMachineOSBuildVariable: ""]) == nil)
    #expect(Packer.buildMachineOSBuild(environment: [Packer.buildMachineOSBuildVariable: "25G83"]) == "25G83")
}

@Test func unknownValuesAreOmittedRatherThanEmpty() {
    let keys = SDKBuildInfo().infoPlistKeys()
    #expect(Set(keys.keys) == ["DTCompiler", "DTPlatformName"])
}

@Test func stampingKeepsExplicitUserValues() {
    var info: [String: any Sendable] = [
        "CFBundleIdentifier": "com.example.app",
        "DTXcode": "9999",
    ]
    Packer.stampBuildInfo(xcode26_5, buildMachineOSBuild: nil, into: &info)

    #expect(info["DTXcode"] as? String == "9999")
    #expect(info["DTXcodeBuild"] as? String == "17F42")
    #expect(info["DTSDKName"] as? String == "iphoneos26.5")
    #expect(info["CFBundleIdentifier"] as? String == "com.example.app")
    #expect(info["BuildMachineOSBuild"] == nil)
}

@Test func buildInfoOnlyAppliesToDeviceBuilds() {
    #expect(Packer.stampsBuildInfo(for: "arm64-apple-ios"))
    #expect(Packer.stampsBuildInfo(for: "arm64-apple-ios17.0"))
    #expect(!Packer.stampsBuildInfo(for: "arm64-apple-ios-simulator"))
    #expect(!Packer.stampsBuildInfo(for: "arm64-apple-macosx"))
}

@Test func buildInfoRoundTripsThroughSDKBundle() throws {
    let bundle = FileManager.default.temporaryDirectory
        .appendingPathComponent("SDKBuildInfoTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundle) }
    try Data("epoch=4\n".utf8).write(to: bundle.appendingPathComponent("darwin-sdk-version.txt"))

    try xcode26_5.write(to: bundle)
    let sdk = try #require(DarwinSDK(bundle: bundle))
    #expect(sdk.flavor == .slim)
    #expect(sdk.buildInfo == xcode26_5)
}

@Test func slimSDKWithoutMetadataDegradesToNil() throws {
    let bundle = FileManager.default.temporaryDirectory
        .appendingPathComponent("SDKBuildInfoTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundle) }
    try Data("epoch=3\n".utf8).write(to: bundle.appendingPathComponent("darwin-sdk-version.txt"))

    let sdk = try #require(DarwinSDK(bundle: bundle))
    #expect(sdk.flavor == .slim)
    #expect(sdk.buildInfo == nil)
}

@Test func normalSDKWithoutMetadataReadsRetainedXcode() throws {
    let xcode = try FakeXcode()
    defer { xcode.cleanUp() }
    // an older normal SDK: <bundle>/Xcode.app, no xtool-sdk-info.json
    let bundle = xcode.root.appendingPathComponent("bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try Data("epoch=3\n".utf8).write(to: bundle.appendingPathComponent("darwin-sdk-version.txt"))
    try FileManager.default.createDirectory(
        at: bundle.appendingPathComponent("Xcode.app"),
        withIntermediateDirectories: true
    )
    try FileManager.default.moveItem(at: xcode.contents, to: bundle.appendingPathComponent("Xcode.app/Contents"))

    let sdk = try #require(DarwinSDK(bundle: bundle))
    #expect(sdk.flavor == .normal)
    #expect(sdk.buildInfo == xcode26_5)
}

@Test func valuesComeFromTheSDKNotFromConstants() throws {
    let xcode = try FakeXcode(
        xcodeVersion: "27.0",
        xcodeBuild: "18A5123a",
        platformBuild: "24A5234b",
        sdkVersion: "27.0",
        sdkBuild: "24A5234c"
    )
    defer { xcode.cleanUp() }

    let keys = xcode.collect().infoPlistKeys()
    #expect(keys["DTXcode"] == "2700")
    #expect(keys["DTXcodeBuild"] == "18A5123a")
    #expect(keys["DTPlatformVersion"] == "27.0")
    #expect(keys["DTPlatformBuild"] == "24A5234b")
    #expect(keys["DTSDKName"] == "iphoneos27.0")
    #expect(keys["DTSDKBuild"] == "24A5234c")
}
