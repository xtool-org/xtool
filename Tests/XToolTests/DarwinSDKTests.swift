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

private func makeSDKBundle(swiftSDKJSON: String?, sdks: [String]) throws -> (URL, DarwinSDK) {
    let bundle = FileManager.default.temporaryDirectory
        .appendingPathComponent("DarwinSDKTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("darwin.artifactbundle", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    if let swiftSDKJSON {
        try Data(swiftSDKJSON.utf8).write(to: bundle.appendingPathComponent("swift-sdk.json"))
    }
    for sdk in sdks {
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Developer/Platforms/iPhoneOS.platform/Developer/SDKs/\(sdk)"),
            withIntermediateDirectories: true
        )
    }
    return (bundle.deletingLastPathComponent(), try #require(DarwinSDK(bundle: bundle)))
}

private let sdkJSON = """
{"targetTriples": {"arm64-apple-ios": {"sdkRootPath": "Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk"}}}
"""

@Test func sdkRootPrefersSwiftSDKMetadataWithoutWarning() throws {
    let (root, sdk) = try makeSDKBundle(swiftSDKJSON: sdkJSON, sdks: ["iPhoneOS27.0.sdk", "iPhoneOS27.1.sdk"])
    defer { try? FileManager.default.removeItem(at: root) }

    var warnings: [String] = []
    let result = sdk.sdkRoot(forTriple: "arm64-apple-ios17.0") { warnings.append($0) }

    #expect(result?.lastPathComponent == "iPhoneOS27.0.sdk")
    #expect(warnings.isEmpty)
}

@Test func sdkRootWarnsWhenMetadataSDKIsNotOnDisk() throws {
    let (root, sdk) = try makeSDKBundle(swiftSDKJSON: sdkJSON, sdks: ["iPhoneOS26.0.sdk", "iPhoneOS27.1.sdk"])
    defer { try? FileManager.default.removeItem(at: root) }

    var warnings: [String] = []
    let result = sdk.sdkRoot(forTriple: "arm64-apple-ios17.0") { warnings.append($0) }

    #expect(result?.lastPathComponent == "iPhoneOS27.1.sdk")
    #expect(warnings.count == 1)
    #expect(warnings.first?.contains("swift-sdk.json") == true)
    #expect(warnings.first?.contains("iPhoneOS27.0.sdk") == true)
    #expect(warnings.first?.contains("iPhoneOS27.1.sdk") == true)
}

@Test func sdkRootWarnsWhenMetadataHasNoEntryForTriple() throws {
    let (root, sdk) = try makeSDKBundle(swiftSDKJSON: sdkJSON, sdks: ["iPhoneOS27.1.sdk"])
    defer { try? FileManager.default.removeItem(at: root) }

    var warnings: [String] = []
    let result = sdk.sdkRoot(forTriple: "arm64-apple-ios17.0-simulator") { warnings.append($0) }

    // only an iPhoneOS SDK is installed, so the simulator fallback finds nothing either
    #expect(result == nil)
    #expect(warnings.count == 1)
    #expect(warnings.first?.contains("no entry") == true)
    #expect(warnings.first?.contains("none found") == true)
}

@Test func sdkRootFallsBackSilentlyWithoutMetadata() throws {
    let (root, sdk) = try makeSDKBundle(swiftSDKJSON: nil, sdks: ["iPhoneOS27.0.sdk", "iPhoneOS27.1.sdk"])
    defer { try? FileManager.default.removeItem(at: root) }

    var warnings: [String] = []
    let result = sdk.sdkRoot(forTriple: "arm64-apple-ios17.0") { warnings.append($0) }

    #expect(result?.lastPathComponent == "iPhoneOS27.1.sdk")
    #expect(warnings.isEmpty)
}

@Test func sdkRootWarnsWhenMetadataCannotBeRead() throws {
    let (root, sdk) = try makeSDKBundle(swiftSDKJSON: nil, sdks: ["iPhoneOS27.1.sdk"])
    defer { try? FileManager.default.removeItem(at: root) }
    // present but not readable as a file
    try FileManager.default.createDirectory(
        at: sdk.bundle.appendingPathComponent("swift-sdk.json"),
        withIntermediateDirectories: false
    )

    var warnings: [String] = []
    let result = sdk.sdkRoot(forTriple: "arm64-apple-ios17.0") { warnings.append($0) }

    #expect(result?.lastPathComponent == "iPhoneOS27.1.sdk")
    #expect(warnings.count == 1)
    #expect(warnings.first?.contains("could not be read") == true)
}
