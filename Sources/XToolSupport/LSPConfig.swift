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
        quiet: Bool = false,
        currentDirectory directory: URL = URL(filePath: FileManager.default.currentDirectoryPath)
    ) async {
        do {
            try await ensure(using: schema, quiet: quiet, currentDirectory: directory)
        } catch {
            print("warning: failed to validate LSP configuration: \(error)")
        }
    }

    nonisolated(nonsending) static func ensure(
        using schema: PackSchema,
        quiet: Bool = false,
        currentDirectory directory: URL = URL(filePath: FileManager.default.currentDirectoryPath)
    ) async throws {
        if schema.skipLSP == true {
            return
        }

        if try await SwiftVersion.current.supportsSwiftBuild {
            try await ensure(primary: bsp, secondary: legacyLSP, quiet: quiet, currentDirectory: directory)
        } else {
            try await ensure(primary: legacyLSP, secondary: bsp, quiet: quiet, currentDirectory: directory)
        }
    }

    // creates the primary LSP-support file if it doesn't exist, and cleans up old files
    private nonisolated(nonsending) static func ensure(
        primary: (String, String),
        secondary: (String, String),
        quiet: Bool,
        currentDirectory directory: URL
    ) async throws {
        let primaryURL = directory.appendingPathComponent(primary.0)
        if FileManager.default.fileExists(atPath: primaryURL.path) {
            return
        }

        try? FileManager.default.createDirectory(
            at: primaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data((primary.1 + "\n").utf8).write(to: primaryURL)

        let secondaryURL = directory.appendingPathComponent(secondary.0)
        if let secondaryData = try? await Data(reading: secondaryURL),
        let secondaryString = String(data: secondaryData, encoding: .utf8),
        secondaryString.trimmingCharacters(in: .whitespacesAndNewlines) == secondary.1 {
            try? FileManager.default.removeItem(at: secondaryURL)
        }

        if !quiet {
            print("""
            [LSP] Created \(primary.0) for enhanced IDE support. You may
                  need to restart your editor for the change to take effect.
                  You can disable this with `skipLSP: true` in xtool.yml.
            """)
        }
    }
}
