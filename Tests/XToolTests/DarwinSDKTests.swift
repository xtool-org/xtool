import Foundation
import Testing
@testable import PackLib

@Test func swiftPMDirectoryUsesXDGConfigHome() throws {
    let directory = try DarwinSDK.swiftPMDirectory(
        environment: ["XDG_CONFIG_HOME": "/xdg/config"],
        homeDirectory: URL(fileURLWithPath: "/home/test")
    )

    #expect(directory.path == "/xdg/config/swiftpm")
}

@Test func swiftPMDirectoryFallsBackToHomeDirectory() throws {
    let directory = try DarwinSDK.swiftPMDirectory(
        environment: [:],
        homeDirectory: URL(fileURLWithPath: "/home/test")
    )

    #expect(directory.path == "/home/test/.swiftpm")
}

@Test func swiftPMDirectoryRejectsRelativeXDGConfigHome() {
    #expect(throws: StringError.self) {
        try DarwinSDK.swiftPMDirectory(
            environment: ["XDG_CONFIG_HOME": "relative/config"],
            homeDirectory: URL(fileURLWithPath: "/home/test")
        )
    }
}

@Test func temporaryDarwinSDKBundleUsesSwiftSDKsDirectory() throws {
    let configDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DarwinSDKTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: configDirectory) }

    let environment = ["XDG_CONFIG_HOME": configDirectory.path]
    let sdksDirectory = configDirectory.appending(path: "swiftpm/swift-sdks")
    let temporaryURL = sdksDirectory.appendingPathComponent("darwin.artifactbundle.tmp", isDirectory: true)
    let installedBundle = sdksDirectory.appending(path: "darwin.artifactbundle")
    try FileManager.default.createDirectory(at: installedBundle, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: false)

    do {
        let temporaryBundle = try DarwinSDK.prepareTemporaryBundle(environment: environment)
        #expect(temporaryBundle.url == temporaryURL)
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))

        try FileManager.default.createDirectory(at: temporaryBundle.url, withIntermediateDirectories: false)
        #expect(DarwinSDK(bundle: temporaryBundle.url)?.version == "develop")
    }

    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    #expect(FileManager.default.fileExists(atPath: installedBundle.path))
}

@Test func sdkRootRequiresInstalledTargetAndDirectory() throws {
    let bundle = FileManager.default.temporaryDirectory
        .appendingPathComponent("DarwinSDKTests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: bundle) }
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try Data("test".utf8).write(to: bundle.appendingPathComponent("darwin-sdk-version.txt"))
    try Data("""
    {"targetTriples":{"arm64-apple-tvos":{"sdkRootPath":"SDKs/AppleTVOS.sdk"}}}
    """.utf8).write(to: bundle.appendingPathComponent("swift-sdk.json"))
    let sdk = try #require(DarwinSDK(bundle: bundle))
    #expect(throws: StringError.self) { try sdk.sdkRoot(for: "arm64-apple-ios") }
    #expect(throws: StringError.self) { try sdk.sdkRoot(for: "arm64-apple-tvos") }
    let root = bundle.appendingPathComponent("SDKs/AppleTVOS.sdk", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    #expect(try sdk.sdkRoot(for: "arm64-apple-tvos") == root)
}
