import Testing
@testable import PackLib
@testable import XToolSupport

@Test(arguments: [
    ("arm64-apple-tvos17.0-simulator", "arm64-apple-tvos-simulator", "17.0"),
    ("arm64-apple-ios18.1", "arm64-apple-ios", "18.1"),
    ("arm64-apple-macos14.0", "arm64-apple-macosx", "14.0"),
    ("x86_64-apple-macos", "x86_64-apple-macosx", nil),
    ("arm64-apple-macosx14.0", "arm64-apple-macosx", "14.0"),
] as [(String, String, String?)])
func nativeSwiftPMUsesRegisteredSDKTriple(triple: String, sdkTriple: String, minimum: String?) async throws {
    let settings = try await BuildSettings(configuration: .debug, triple: triple, buildSystem: .swiftPM)
    #expect(settings.sdkOptions.starts(with: ["--swift-sdk", sdkTriple]))
    #expect(settings.tripleDeploymentTarget == minimum)
}

@Test func macOSAliasUsesCanonicalCompilerTriple() async throws {
    let settings = try await BuildSettings(configuration: .debug, triple: "arm64-apple-macos14.0", buildSystem: .swiftPM)
    #expect(settings.triple(deploymentTarget: "15.0") == "arm64-apple-macosx15.0")
}

@Test(arguments: ["arm64-apple-watchos", "arm64-apple-visionos", "arm64-apple-tvo"])
func rejectsUnsupportedBuildTargets(triple: String) async throws {
    do {
        _ = try await BuildSettings(configuration: .debug, triple: triple, buildSystem: .swiftPM)
        Issue.record("Expected BuildSettings to reject \(triple)")
    } catch {
        #expect(String(describing: error).contains("Unsupported target triple '\(triple)'"))
    }
}

@Test(arguments: ["arm64-apple-watchos", "arm64-apple-visionos", "arm64-apple-tvo"])
func devBuildRejectsUnsupportedTargetsBeforeSetup(triple: String) async throws {
    let command = try DevBuildCommand.parse(["--triple", triple])
    do {
        try await command.run()
        Issue.record("Expected the build command to reject \(triple)")
    } catch {
        #expect(String(describing: error).contains("Unsupported target triple '\(triple)'"))
        #expect(String(describing: error).contains("iOS, tvOS, macOS, macCatalyst"))
    }
}
