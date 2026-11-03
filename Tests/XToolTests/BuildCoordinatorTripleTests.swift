import CustomDump
import Dependencies
import Foundation
import SwiftBuild
import Testing
import XPIF
import XUtils
@testable import XToolSupport

#if os(macOS)
struct BuildCoordinatorTripleTests {
    @Test(.requiresXcode, arguments: [
        ("arm64-apple-ios", "arm64", "iphoneos", nil, "IPHONEOS_DEPLOYMENT_TARGET", "16.0"),
        ("arm64e-apple-ios17.0", "arm64e", "iphoneos", nil, "IPHONEOS_DEPLOYMENT_TARGET", "17.0"),
        ("arm64-apple-ios17.2-simulator", "arm64", "iphonesimulator", nil, "IPHONEOS_DEPLOYMENT_TARGET", "17.2"),
        ("x86_64-apple-ios17.0-simulator", "x86_64", "iphonesimulator", nil, "IPHONEOS_DEPLOYMENT_TARGET", "17.0"),
        ("arm64-apple-ios17.0-macabi", "arm64", "macosx", "iosmac", "IPHONEOS_DEPLOYMENT_TARGET", "17.0"),
        ("arm64-apple-macos14.0", "arm64", "macosx", nil, "MACOSX_DEPLOYMENT_TARGET", "14.0"),
    ] as [(String, String, String, String?, String, String)])
    func resolvesTriple(
        triple: String, arch: String, platform: String, variant: String?, deploymentSetting: String, deployment: String
    ) async throws {
        let directory = try TemporaryDirectory(name: "BuildCoordinatorTripleTests")
        let description = try await description(triple: triple, root: directory.url)
        let coordinator = try await withDependencies {
            $0.out = .liveValue
        } operation: {
            try await BuildCoordinator(description: description)
        }
        defer { await coordinator.close() }
        let parameters = await coordinator.buildRequest.parameters
        let destination = try #require(parameters.activeRunDestination)
        let expectedTarget = SWBRunDestinationInfo.SWBBuildTarget.toolchainSDK(
            platform: platform, sdk: platform, sdkVariant: variant
        )
        expectNoDifference(diff(destination.buildTarget, expectedTarget), nil)
        expectNoDifference(destination.targetArchitecture, arch)
        expectNoDifference(parameters.activeArchitecture, arch)
        let session = await coordinator.sessionManager.session
        let actualDeployment = try await session.evaluateMacroAsString(
            deploymentSetting, level: .project("project"), buildParameters: parameters, overrides: nil
        )
        expectNoDifference(actualDeployment, deployment)
    }

    @Test(.requiresXcode, arguments: ["arm64", "arm64-apple-ios-invalid-version", "arm64-apple-unrecognized"])
    func rejectsInvalidTriples(triple: String) async throws {
        let directory = try TemporaryDirectory(name: "InvalidTripleTests")
        let description = try await description(triple: triple, root: directory.url)
        await #expect(throws: (any Error).self) {
            let coordinator = try await BuildCoordinator(description: description)
            await coordinator.close()
        }
    }

    private func description(triple: String, root: URL) async throws -> BuildDescription {
        let settings = try await BuildSettings(configuration: .debug, triple: triple)
        var projectSettings = XPIF.BuildSettings()
        projectSettings[.SDKROOT] = "auto"
        projectSettings[.IPHONEOS_DEPLOYMENT_TARGET] = "16.0"
        projectSettings[.MACOSX_DEPLOYMENT_TARGET] = "13.0"
        let project = XPIF.Project(
            id: "project", path: root.appending(path: "Package.swift").path, projectDir: root.path, name: "Package",
            buildConfigs: [.init(id: "debug", name: "Debug", settings: projectSettings)]
        )
        let pif = XPIF.Container(workspace: .init(id: "workspace", name: "Package", path: root.path, projects: [project]))
        return BuildDescription(pif: pif, buildSettings: settings)
    }
}
#endif
