#if os(macOS)
import Foundation
import Testing
import XUtils
import XPIF
@testable import XToolSupport

struct MetalToolchainTests {
    @Test func decodesInstalledComponent() throws {
        let component = try #require(MetalToolchain.installedComponent(from: Data("""
            {"status":"installed","toolchainIdentifier":"com.apple.dt.toolchain.Metal.123",
             "toolchainSearchPath":"/path with spaces/Metal","buildVersion":"123"}
            """.utf8)))
        #expect(component.toolchainIdentifier == "com.apple.dt.toolchain.Metal.123")
        #expect(component.toolchainSearchPath == "/path with spaces/Metal")
    }

    @Test(arguments: [
        "{}", "not JSON", "{\"status\":\"not installed\"}",
        """
        {"status":"available","toolchainIdentifier":"metal","toolchainSearchPath":"/Metal"}
        """,
        """
        {"status":"installed","toolchainIdentifier":"","toolchainSearchPath":"/Metal"}
        """,
        """
        {"status":"installed","toolchainIdentifier":"metal","toolchainSearchPath":""}
        """,
    ])
    func ignoresUnavailableComponent(json: String) {
        #expect(MetalToolchain.installedComponent(from: Data(json.utf8)) == nil)
    }

    @Test func preservesExistingSearchPaths() {
        let component = MetalToolchain(toolchainIdentifier: "metal", toolchainSearchPath: "/Metal")
        let environment = component.sessionEnvironment(inheriting: [
            "EXTERNAL_TOOLCHAINS_DIR": "/first:/second", "DEVELOPER_DIR": "/Xcode",
        ])
        #expect(environment["EXTERNAL_TOOLCHAINS_DIR"] == "/first:/second:/Metal")
        #expect(environment["DEVELOPER_DIR"] == "/Xcode")
        #expect(component.sessionEnvironment(inheriting: [:])["EXTERNAL_TOOLCHAINS_DIR"] == "/Metal")
        #expect(component.sessionEnvironment(inheriting: ["EXTERNAL_TOOLCHAINS_DIR": ""])["EXTERNAL_TOOLCHAINS_DIR"] == "/Metal")
    }

    @Test func appendsSearchPathOnce() {
        let component = MetalToolchain(toolchainIdentifier: "metal", toolchainSearchPath: "/Metal")
        #expect(component.externalToolchainsDir(appendingTo: "/first:/Metal") == "/first:/Metal")
        #expect(component.externalToolchainsDir(appendingTo: nil) == "/Metal")
    }

    @Test(.requiresXcode) func registersAndSelectsInstalledToolchain() async throws {
        guard let component = await MetalToolchain.current.value else {
            try Test.cancel(Self.notInstalled)
        }
        let (toolchains, directories) = try await Self.evaluateToolchainSettings()
        #expect(toolchains.split(separator: " ").first == Substring(component.toolchainIdentifier))
        #expect(directories.contains(component.toolchainSearchPath))
    }

    /// Swift Build snapshots the process environment on first use, so this runs in a fresh process.
    @Test(.requiresXcode) func registersToolchainWhenProcessDefinesSearchPath() async throws {
        guard await MetalToolchain.current.value != nil else {
            try Test.cancel(Self.notInstalled)
        }
        await #expect(processExitsWith: .success) {
            setenv("EXTERNAL_TOOLCHAINS_DIR", "/nonexistent-xtool-toolchains", 1)
            let component = try #require(await MetalToolchain.current.value)
            let (toolchains, directories) = try await MetalToolchainTests.evaluateToolchainSettings()
            #expect(toolchains.split(separator: " ").first == Substring(component.toolchainIdentifier))
            #expect(directories.contains(component.toolchainSearchPath))
            #expect(ProcessInfo.processInfo.environment["EXTERNAL_TOOLCHAINS_DIR"]
                == "/nonexistent-xtool-toolchains:\(component.toolchainSearchPath)")
        }
    }

    private static let notInstalled: Comment =
        "Metal toolchain component is not installed. Run: xcodebuild -downloadComponent MetalToolchain"

    private static func evaluateToolchainSettings() async throws -> (toolchains: String, directories: String) {
        let directory = try TemporaryDirectory(name: "MetalToolchainTests")
        var settings = XPIF.BuildSettings()
        settings[.SDKROOT] = "auto"
        let project = XPIF.Project(
            id: "project", path: directory.url.appending(path: "Package.swift").path,
            projectDir: directory.url.path, name: "Metal",
            buildConfigs: [.init(id: "debug", name: "Debug", settings: settings)]
        )
        let pif = XPIF.Container(workspace: .init(
            id: "workspace", name: "Metal", path: directory.url.path, projects: [project]
        ))
        let coordinator = try await BuildCoordinator(description: .init(
            directory: directory.url, pif: pif, configuration: .debug, triple: "arm64-apple-ios"
        ))
        defer { await coordinator.close() }
        let session = await coordinator.sessionManager.session
        let parameters = await coordinator.buildRequest.parameters
        let toolchains = try await session.evaluateMacroAsString(
            "TOOLCHAINS", level: .project("project"), buildParameters: parameters, overrides: nil
        )
        let directories = try await session.evaluateMacroAsString(
            "EFFECTIVE_TOOLCHAINS_DIRS", level: .project("project"), buildParameters: parameters, overrides: nil
        )
        return (toolchains, directories)
    }
}
#endif
