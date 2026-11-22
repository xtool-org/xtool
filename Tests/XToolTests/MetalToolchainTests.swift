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
        let component = MetalToolchain(status: "installed", toolchainIdentifier: "metal", toolchainSearchPath: "/Metal")
        let environment = component.sessionEnvironment(inheriting: [
            "EXTERNAL_TOOLCHAINS_DIR": "/first:/second", "DEVELOPER_DIR": "/Xcode",
        ])
        #expect(environment["EXTERNAL_TOOLCHAINS_DIR"] == "/first:/second:/Metal")
        #expect(environment["DEVELOPER_DIR"] == "/Xcode")
        #expect(component.sessionEnvironment(inheriting: [:])["EXTERNAL_TOOLCHAINS_DIR"] == "/Metal")
        #expect(component.sessionEnvironment(inheriting: ["EXTERNAL_TOOLCHAINS_DIR": ""])["EXTERNAL_TOOLCHAINS_DIR"] == "/Metal")
    }

    @Test(.requiresXcode) func registersAndSelectsInstalledToolchain() async throws {
        guard let component = await MetalToolchain.current.value else { return }
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
        #expect(toolchains.split(separator: " ").first == Substring(component.toolchainIdentifier))
        let directories = try await session.evaluateMacroAsString(
            "EFFECTIVE_TOOLCHAINS_DIRS", level: .project("project"), buildParameters: parameters, overrides: nil
        )
        #expect(directories.contains(component.toolchainSearchPath))
    }
}
#endif
