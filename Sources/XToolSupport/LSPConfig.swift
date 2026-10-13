import Foundation
import PackLib

enum LSPConfig {
    static let bsp: (String, String) = (
        ".bsp/xtool.json",
        """
        {
            "name": "xtool",
            "version": "1.0",
            "bspVersion": "2.2.0",
            "languages": ["c", "cpp", "objective-c", "objective-cpp", "swift"],
            "argv": ["/usr/bin/env", "xtool", "dev", "build-server"]
        }
        """
    )

    static let legacyLSP: (String, String) = (
        ".sourcekit-lsp/config.json",
        """
        {
            "swiftPM": {
                "swiftSDK": "arm64-apple-ios"
            }
        }
        """
    )

    nonisolated(nonsending) static func tryEnsure(
        using schema: PackSchema,
        cliTriple: String? = nil,
        quiet: Bool = false,
        currentDirectory directory: URL = URL(filePath: FileManager.default.currentDirectoryPath)
    ) async {
        do {
            try await ensure(using: schema, cliTriple: cliTriple, quiet: quiet, currentDirectory: directory)
        } catch {
            print("warning: failed to validate LSP configuration: \(error)")
        }
    }

    nonisolated(nonsending) static func ensure(
        using schema: PackSchema,
        cliTriple: String? = nil,
        quiet: Bool = false,
        currentDirectory directory: URL = URL(filePath: FileManager.default.currentDirectoryPath)
    ) async throws {
        if schema.skipLSP == true {
            return
        }

        let request = try DevBuildRequest(schema: schema, cliTriple: cliTriple, directory: directory)
        let (settings, target) = try await EditorTarget.buildSettings(request: request)
        try ensure(target: target, sdkOptions: settings.sdkOptions,
                   supportsBSP: try await SwiftVersion.current.supportsSwiftBuild,
                   quiet: quiet, currentDirectory: directory)
    }

    /// Builds already planned the package; reuse that plan instead of inspecting the package again.
    nonisolated(nonsending) static func tryEnsure(
        plan: Plan,
        settings: BuildSettings,
        schema: PackSchema,
        currentDirectory directory: URL = URL(filePath: FileManager.default.currentDirectoryPath)
    ) async {
        guard schema.skipLSP != true else { return }
        do {
            try ensure(target: plan.target, sdkOptions: settings.withTarget(plan.target).sdkOptions,
                       supportsBSP: try await SwiftVersion.current.supportsSwiftBuild, currentDirectory: directory)
        } catch {
            print("warning: failed to validate LSP configuration: \(error)")
        }
    }

    static func configuration(target: ResolvedTarget, sdkOptions: [String], bsp: Bool) throws -> (String, String) {
        let object: [String: Any]
        let path: String
        if bsp {
            path = Self.bsp.0
            object = [
                "name": "xtool", "version": "1.0", "bspVersion": "2.2.0",
                "languages": ["c", "cpp", "objective-c", "objective-cpp", "swift"],
                "argv": ["/usr/bin/env", "xtool", "dev", "build-server", "--triple", target.triple],
            ]
        } else {
            path = legacyLSP.0
            let sdkIndex = sdkOptions.firstIndex(of: "--swift-sdk")
            // Legacy SourceKit uses SwiftPM even when builds default to SwiftBuild.
            let sdkPlatform = switch target.platform {
            case .iOS: "ios"
            case .iOSSimulator: "ios-simulator"
            case .macOS: "macosx"
            }
            let sdk = sdkIndex.map { sdkOptions[$0 + 1] } ?? "\(target.architecture)-apple-\(sdkPlatform)"
            object = ["swiftPM": ["swiftSDK": sdk, "triple": target.compilerTriple]]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return (path, String(decoding: data, as: UTF8.self))
    }

    static func ensure(
        target: ResolvedTarget, sdkOptions: [String], supportsBSP: Bool, quiet: Bool = false, currentDirectory directory: URL
    ) throws {
        let primary = try configuration(target: target, sdkOptions: sdkOptions, bsp: supportsBSP)
        let secondary = try configuration(target: target, sdkOptions: sdkOptions, bsp: !supportsBSP)
        let primaryURL = directory.appendingPathComponent(primary.0)
        if FileManager.default.fileExists(atPath: primaryURL.path) {
            let data = try Data(contentsOf: primaryURL)
            guard isGenerated(data, bsp: supportsBSP) else { return }
        }
        try FileManager.default.createDirectory(at: primaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((primary.1 + "\n").utf8).write(to: primaryURL, options: .atomic)

        let secondaryURL = directory.appendingPathComponent(secondary.0)
        if FileManager.default.fileExists(atPath: secondaryURL.path),
           isGenerated(try Data(contentsOf: secondaryURL), bsp: !supportsBSP) {
            try FileManager.default.removeItem(at: secondaryURL)
        }
        if !quiet {
            print("""
            [LSP] Configured \(primary.0) for enhanced IDE support. You may
                  need to restart your editor for the change to take effect.
                  You can disable this with `skipLSP: true` in xtool.yml.
            """)
        }
    }

    /// Recognize complete generated shapes; any extra key or changed value is user-owned.
    private static func isGenerated(_ data: Data, bsp: Bool) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? NSDictionary else { return false }
        let original = bsp ? Self.bsp.1 : legacyLSP.1
        if let old = try? JSONSerialization.jsonObject(with: Data(original.utf8)) as? NSDictionary, object == old {
            return true
        }
        let triple: String?
        if bsp {
            let argv = object["argv"] as? [String]
            triple = argv?.count == 6 ? argv?.last : nil
        } else {
            triple = (object["swiftPM"] as? [String: String])?["triple"]
        }
        guard let triple, let target = try? ResolvedTarget.resolve(cliTarget: triple),
              let expected = try? configuration(target: target, sdkOptions: [], bsp: bsp),
              let generated = try? JSONSerialization.jsonObject(with: Data(expected.1.utf8)) as? NSDictionary else {
            return false
        }
        return object == generated
    }
}

/// Use the same package deployment minima and target contract as app builds.
enum EditorTarget {
    nonisolated(nonsending) static func buildSettings(request: DevBuildRequest) async throws -> (BuildSettings, ResolvedTarget) {
        let settings = try await BuildSettings(configuration: .debug, triple: request.triple, packagePath: request.directory.path)
        let plan = try await Planner(buildSettings: settings, schema: request.schema).createPlan()
        return (try settings.withTarget(plan.target), plan.target)
    }
}
