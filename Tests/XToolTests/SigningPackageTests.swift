import Foundation
import Testing
import Dependencies
import XKit
@testable import XToolSupport

@Test func signingStagesCopyAndPublishesWithoutChangingInput() async throws {
    let root = try signingFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeSigningFixture(in: root, platforms: ["AppleTVOS"])
    let output = root.appendingPathComponent("Signed.app")
    let package = try await SigningPackage(input: app, output: output, platform: nil)
    #expect(package.platform == .tvOS)
    try Data("signed".utf8).write(to: package.app.appendingPathComponent("Example"))
    try await package.export(to: output)
    #expect(try String(contentsOf: app.appendingPathComponent("Example"), encoding: .utf8) == "original")
    #expect(try String(contentsOf: output.appendingPathComponent("Example"), encoding: .utf8) == "signed")
}

@Test(arguments: [["MacOSX"], ["AppleTVSimulator"], ["iPhoneSimulator"], ["iPhoneOS", "AppleTVOS"]])
func signingRejectsUnsupportedPlatformBeforeProvisioning(platforms: [String]) async throws {
    let root = try signingFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeSigningFixture(in: root, platforms: platforms)
    await #expect(throws: (any Error).self) {
        _ = try await SigningPackage(input: app, output: root.appendingPathComponent("out.ipa"), platform: nil)
    }
}

@Test func signingRejectsPlatformMismatchAndExistingOrNestedOutput() async throws {
    let root = try signingFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeSigningFixture(in: root, platforms: ["AppleTVOS"])
    for (output, platform) in [
        (root.appendingPathComponent("out.ipa"), SigningPlatform.iOS),
        (app, .tvOS),
        (app.appendingPathComponent("nested.app"), .tvOS),
    ] {
        await #expect(throws: (any Error).self) {
            _ = try await SigningPackage(input: app, output: output, platform: platform)
        }
    }
}

@Test func signingRejectsAmbiguousArchive() async throws {
    let root = try signingFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("input.ipa")
    try Data().write(to: input)
    await withDependencies {
        $0.zipCompressor.decompress = { _, directory, _ in
            let payload = directory.appendingPathComponent("Payload")
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            _ = try makeSigningFixture(in: payload, platforms: ["AppleTVOS"])
            _ = try makeSigningFixture(in: payload, platforms: ["AppleTVOS"], name: "Other.app")
        }
    } operation: {
        await #expect(throws: (any Error).self) {
            _ = try await SigningPackage(input: input, output: root.appendingPathComponent("out.ipa"), platform: nil)
        }
    }
}

@Test func signingArchiveRoundTripAndCompressionFailurePreserveInput() async throws {
    let root = try signingFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("input.ipa")
    let output = root.appendingPathComponent("out.ipa")
    try Data("original archive".utf8).write(to: input)
    try await withDependencies {
        $0.zipCompressor.decompress = { _, directory, _ in
            let payload = directory.appendingPathComponent("Payload")
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            _ = try makeSigningFixture(in: payload, platforms: ["AppleTVOS"])
        }
        $0.zipCompressor.compress = { _, _ in throw CocoaError(.fileWriteUnknown) }
    } operation: {
        let package = try await SigningPackage(input: input, output: output, platform: nil)
        await #expect(throws: (any Error).self) { try await package.export(to: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try await withDependencies {
            $0.zipCompressor.compress = { payload, _ in
                #expect(payload.lastPathComponent == "Payload")
                let archive = payload.deletingLastPathComponent().appendingPathComponent("app.ipa")
                try Data("signed archive".utf8).write(to: archive)
                return archive
            }
        } operation: {
            try await package.export(to: output)
        }
    }
    #expect(try String(contentsOf: input, encoding: .utf8) == "original archive")
    #expect(try String(contentsOf: output, encoding: .utf8) == "signed archive")
}

@Test func signingDoesNotOverwriteOutputCreatedWhileSigning() async throws {
    let root = try signingFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeSigningFixture(in: root, platforms: ["iPhoneOS"])
    let output = root.appendingPathComponent("out.app")
    let package = try await SigningPackage(input: app, output: output, platform: nil)
    try Data("keep".utf8).write(to: output)
    await #expect(throws: (any Error).self) { try await package.export(to: output) }
    #expect(try String(contentsOf: output, encoding: .utf8) == "keep")
}

private func signingFixtureDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func signingRejectsExtensionSymlinkOutsideStaging() async throws {
    let root = try signingFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeSigningFixture(in: root, platforms: ["AppleTVOS"])
    let originalExtension = try makeSigningFixture(in: root, platforms: ["AppleTVOS"], name: "Original.appex")
    let originalInfo = try Data(contentsOf: originalExtension.appendingPathComponent("Info.plist"))
    let plugins = app.appendingPathComponent("PlugIns")
    try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
        at: plugins.appendingPathComponent("Linked.appex"),
        withDestinationURL: originalExtension
    )
    await #expect(throws: (any Error).self) {
        _ = try await SigningPackage(input: app, output: root.appendingPathComponent("out.ipa"), platform: nil)
    }
    #expect(try Data(contentsOf: originalExtension.appendingPathComponent("Info.plist")) == originalInfo)
}

@Test(arguments: ["conflict", "unsupportedFamily", "malformedPlatforms", "emptyPlatforms", "malformedFamily", "emptyFamily"])
func signingRejectsContradictoryOrMalformedMetadata(scenario: String) async throws {
    let root = try signingFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeSigningFixture(in: root, platforms: ["AppleTVOS"])
    let info = app.appendingPathComponent("Info.plist")
    var plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any])
    switch scenario {
    case "conflict": plist["UIDeviceFamily"] = [1]
    case "unsupportedFamily": plist["UIDeviceFamily"] = [6]
    case "malformedPlatforms": plist["CFBundleSupportedPlatforms"] = "AppleTVOS"
    case "emptyPlatforms": plist["CFBundleSupportedPlatforms"] = [String]()
    case "malformedFamily": plist["UIDeviceFamily"] = "3"
    default: plist["UIDeviceFamily"] = [Int]()
    }
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
    await #expect(throws: (any Error).self) {
        _ = try await SigningPackage(input: app, output: root.appendingPathComponent("out.ipa"), platform: .tvOS)
    }
}

@discardableResult
private func makeSigningFixture(in root: URL, platforms: [String], name: String = "Example.app") throws -> URL {
    let app = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": "com.example.test", "CFBundleExecutable": "Example",
                               "CFBundleSupportedPlatforms": platforms]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Info.plist"))
    try Data("original".utf8).write(to: app.appendingPathComponent("Example"))
    return app
}
