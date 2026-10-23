import ArgumentParser
import Dependencies
import Foundation
import Testing
@testable import PackLib
@testable import XToolSupport

struct EditorConfigTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ config: (String, String), to root: URL) throws {
        let url = root.appendingPathComponent(config.0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(config.1.utf8).write(to: url)
    }

    private func read(_ path: String, in root: URL) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(path))
    }

    @Test(arguments: [true, false])
    func newConfigurationsKeepIOSDefaultAndSelectMacOS(bsp: Bool) throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ios = try ResolvedTarget.resolve()
        try LSPConfig.ensure(target: ios, sdkOptions: [], supportsBSP: bsp, quiet: true, currentDirectory: directory)
        let path = bsp ? LSPConfig.bsp.0 : LSPConfig.legacyLSP.0
        let iosText = String(decoding: try read(path, in: directory), as: UTF8.self)
        #expect(iosText.contains("arm64-apple-ios"))
        let mac = try ResolvedTarget.resolve(cliTarget: "x86_64-apple-macos15.0")
        try LSPConfig.ensure(target: mac, sdkOptions: [], supportsBSP: bsp, quiet: true, currentDirectory: directory)
        let object = try #require(JSONSerialization.jsonObject(with: read(path, in: directory)) as? [String: Any])
        if bsp {
            #expect(object["argv"] as? [String] == [
                "/usr/bin/env", "xtool", "dev", "build-server", "--triple", "x86_64-apple-macosx15.0",
            ])
        } else {
            #expect(object["swiftPM"] as? [String: String] == [
                "swiftSDK": "x86_64-apple-macosx", "triple": "x86_64-apple-macosx15.0",
            ])
        }
    }

    @Test(arguments: [true, false])
    func oldGeneratedConfigsMigrateInBothDirections(bsp: Bool) throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(LSPConfig.bsp, to: directory)
        try write(LSPConfig.legacyLSP, to: directory)
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx16.0")
        try LSPConfig.ensure(target: target, sdkOptions: [], supportsBSP: bsp, quiet: true, currentDirectory: directory)
        let primary = bsp ? LSPConfig.bsp.0 : LSPConfig.legacyLSP.0
        let secondary = bsp ? LSPConfig.legacyLSP.0 : LSPConfig.bsp.0
        #expect(String(decoding: try read(primary, in: directory), as: UTF8.self).contains("arm64-apple-macosx16.0"))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(secondary).path))
        // Reversing direction recognizes the newly generated content too.
        try LSPConfig.ensure(target: target, sdkOptions: [], supportsBSP: !bsp, quiet: true, currentDirectory: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(primary).path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(secondary).path))
    }

    @Test(arguments: [true, false])
    func userPrimaryPreservesBothFiles(bsp: Bool) throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = bsp ? LSPConfig.bsp.0 : LSPConfig.legacyLSP.0
        let secondary = bsp ? LSPConfig.legacyLSP : LSPConfig.bsp
        let userContent = "{\"custom\": true}"
        try write((primary, userContent), to: directory)
        try write(secondary, to: directory)
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx")
        try LSPConfig.ensure(target: target, sdkOptions: [], supportsBSP: bsp, quiet: true, currentDirectory: directory)
        #expect(try read(primary, in: directory) == Data(userContent.utf8))
        #expect(try read(secondary.0, in: directory) == Data(secondary.1.utf8))
    }

    @Test(arguments: [true, false])
    func userSecondaryIsNeverDeleted(bsp: Bool) throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx")
        let secondary = try LSPConfig.configuration(target: target, sdkOptions: [], bsp: !bsp)
        var object = try #require(JSONSerialization.jsonObject(with: Data(secondary.1.utf8)) as? [String: Any])
        object["custom"] = true
        let contents = try JSONSerialization.data(withJSONObject: object)
        try write((secondary.0, String(decoding: contents, as: UTF8.self)), to: directory)
        try LSPConfig.ensure(target: target, sdkOptions: [], supportsBSP: bsp, quiet: true, currentDirectory: directory)
        #expect(try read(secondary.0, in: directory) == contents)
    }

    @Test(arguments: [true, false])
    func changedGeneratedValuesAreUserOwned(bsp: Bool) throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = try ResolvedTarget.resolve()
        let generated = try LSPConfig.configuration(target: target, sdkOptions: [], bsp: bsp)
        let customized = bsp ? generated.1.replacingOccurrences(of: "xtool", with: "custom-tool")
            : generated.1.replacingOccurrences(of: "arm64-apple-ios13.0", with: "arm64-apple-ios12.0")
        try write((generated.0, customized), to: directory)
        let mac = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx")
        try LSPConfig.ensure(target: mac, sdkOptions: [], supportsBSP: bsp, quiet: true, currentDirectory: directory)
        #expect(try read(generated.0, in: directory) == Data(customized.utf8))
    }

    @Test func malformedPrimaryIsPreserved() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write((LSPConfig.legacyLSP.0, "not JSON"), to: directory)
        let target = try ResolvedTarget.resolve()
        try LSPConfig.ensure(target: target, sdkOptions: [], supportsBSP: false, quiet: true, currentDirectory: directory)
        #expect(try read(LSPConfig.legacyLSP.0, in: directory) == Data("not JSON".utf8))
    }

    @Test func skipLSPAvoidsInspectionAndWrites() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = try PackSchema(validating: .init(version: .v1, orgID: "test", skipLSP: true))
        try await LSPConfig.ensure(using: schema, quiet: true, currentDirectory: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private func inspection(root: URL, platform: String, minimum: String) throws -> PackageInspectionClient {
        let dependencies = try JSONSerialization.data(withJSONObject: [
            "identity": "root", "path": root.path, "dependencies": [],
        ])
        let description = try JSONSerialization.data(withJSONObject: [
            "name": "Fixture", "platforms": [["name": platform, "version": minimum]],
            "products": [["name": "App", "targets": ["Main"], "type": ["executable": NSNull()]]],
            "targets": [["name": "Main", "type": "executable", "module_type": "SwiftTarget", "resources": []]],
        ])
        let manifest = try JSONSerialization.data(withJSONObject: [
            "targets": [["name": "Main", "type": "executable", "dependencies": []]], "dependencies": [],
        ])
        return PackageInspectionClient(
            dependencies: { _ in dependencies }, describe: { _ in description }, manifest: { _ in manifest }
        )
    }

    @Test(arguments: [nil, "x86_64-apple-macosx17.0"])
    func buildServerMatchesPlannerTargetAndDeployment(override: String?) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = try PackSchema(validating: .init(
            version: .v2, orgID: "test", product: "App", target: "arm64-apple-macosx", deploymentTarget: "16.0"
        ))
        let command = try DevBSPCommand.parse(override.map { ["--triple", $0] } ?? [])
        let request = try DevBuildRequest(schema: schema, cliTriple: command.triple, directory: directory)
        let inspector = try inspection(root: directory, platform: "macos", minimum: "15.0")
        try await withDependencies {
            $0.packageInspection = inspector
        } operation: {
            let (settings, target) = try await EditorTarget.buildSettings(request: request)
            #expect(settings.buildSystem == .swiftPM)
            #expect(settings.sdkOptions == [
                "--swift-sdk", override == nil ? "arm64-apple-macosx" : "x86_64-apple-macosx",
                "--triple", override ?? "arm64-apple-macosx16.0",
            ])
            let plan = try await Planner(buildSettings: settings, schema: schema).createPlan()
            #expect(plan.target == target)
            #expect(settings.buildServerArguments.contains(target.compilerTriple))
            let config = try LSPConfig.configuration(target: target, sdkOptions: settings.sdkOptions, bsp: false)
            #expect(config.1.contains(target.compilerTriple))
        }
    }

    @Test func buildServerStartsWithoutInspectingThePackage() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = try PackSchema(validating: .init(version: .v2, orgID: "test", product: "App", target: "arm64-apple-macosx"))
        let request = try DevBuildRequest(schema: schema, cliTriple: "arm64-apple-macosx16.0", directory: directory)
        let settings = try await withDependencies {
            $0.packageInspection = PackageInspectionClient(
                dependencies: { _ in Issue.record("Unexpected package inspection"); return Data() },
                describe: { _ in Issue.record("Unexpected package inspection"); return Data() },
                manifest: { _ in Issue.record("Unexpected package inspection"); return Data() }
            )
        } operation: {
            try await EditorTarget.serverSettings(request: request)
        }
        #expect(settings.sdkOptions == ["--swift-sdk", "arm64-apple-macosx", "--triple", "arm64-apple-macosx16.0"])
        // Configurations generated with the unversioned triple are still recognized and refreshed.
        let old = (LSPConfig.bsp.0, """
        {"argv": ["/usr/bin/env", "xtool", "dev", "build-server", "--triple", "arm64-apple-macosx"],
         "bspVersion": "2.2.0", "languages": ["c", "cpp", "objective-c", "objective-cpp", "swift"],
         "name": "xtool", "version": "1.0"}
        """)
        try write(old, to: directory)
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx16.0")
        try LSPConfig.ensure(target: target, sdkOptions: [], supportsBSP: true, quiet: true, currentDirectory: directory)
        #expect(String(decoding: try read(LSPConfig.bsp.0, in: directory), as: UTF8.self).contains("arm64-apple-macosx16.0"))
    }

    @Test(arguments: [true, false])
    func buildServerKeepsIOSDefaultAndPackageMinimum(bsp: Bool) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = try PackSchema(validating: .init(version: .v1, orgID: "test", product: "App"))
        let inspector = try inspection(root: directory, platform: "ios", minimum: "14.0")
        try await withDependencies {
            $0.packageInspection = inspector
        } operation: {
            let request = try DevBuildRequest(schema: schema, directory: directory)
            let (settings, target) = try await EditorTarget.buildSettings(request: request)
            #expect(request.triple == ResolvedTarget.defaultTriple)
            #expect(target.compilerTriple == "arm64-apple-ios14.0")
            // SwiftBuild keeps the unversioned triple so packages index at their own minimums, as they build.
            let indexTriple = settings.buildSystem == .swiftBuild ? "arm64-apple-ios" : "arm64-apple-ios14.0"
            #expect(settings.buildServerArguments.suffix(2) == ["--triple", indexTriple])
            let config = try LSPConfig.configuration(target: target, sdkOptions: settings.sdkOptions, bsp: bsp)
            let object = try #require(JSONSerialization.jsonObject(with: Data(config.1.utf8)) as? [String: Any])
            if bsp {
                #expect(config.0 == LSPConfig.bsp.0)
                #expect(object["argv"] as? [String] == [
                    "/usr/bin/env", "xtool", "dev", "build-server", "--triple", "arm64-apple-ios14.0",
                ])
            } else {
                #expect(config.0 == LSPConfig.legacyLSP.0)
                #expect(object["swiftPM"] as? [String: String] == [
                    "swiftSDK": "arm64-apple-ios", "triple": "arm64-apple-ios14.0",
                ])
            }
        }
    }

    @Test func packageMinimumControlsEditorAndRejectsLowerOverrides() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = try PackSchema(validating: .init(version: .v2, orgID: "test", product: "App", target: "arm64-apple-macosx"))
        let inspector = try inspection(root: directory, platform: "macos", minimum: "16.0")
        try await withDependencies {
            $0.packageInspection = inspector
        } operation: {
            let request = try DevBuildRequest(schema: schema, directory: directory)
            let (_, target) = try await EditorTarget.buildSettings(request: request)
            #expect(target.compilerTriple == "arm64-apple-macosx16.0")
            let lower = try DevBuildRequest(schema: schema, cliTriple: "arm64-apple-macosx15.0", directory: directory)
            await #expect(throws: (any Error).self) { try await EditorTarget.buildSettings(request: lower) }
        }
    }
}
