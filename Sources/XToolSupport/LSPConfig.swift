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
        currentDirectory directory: URL = URL(filePath: FileManager.default.currentDirectoryPath)
    ) async {
        do {
            try await ensure(using: schema, currentDirectory: directory)
        } catch {
            print("warning: failed to validate LSP configuration: \(error)")
        }
    }

    nonisolated(nonsending) static func ensure(
        using schema: PackSchema,
        currentDirectory directory: URL = URL(filePath: FileManager.default.currentDirectoryPath)
    ) async throws {
        if schema.skipBSPCreation == true {
            return
        }

        let bspURL = directory.appendingPathComponent(bsp.0)
        if FileManager.default.fileExists(atPath: bspURL.path) {
            return
        }

        guard try await SwiftVersion.current.supportsSwiftBuild else {
            return
        }

        try? FileManager.default.createDirectory(
            at: bspURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data((bsp.1 + "\n").utf8).write(to: bspURL)

        let lspURL = directory.appendingPathComponent(legacyLSP.0)
        if let lspData = try? await Data(reading: lspURL),
           let lspString = String(data: lspData, encoding: .utf8),
           lspString.trimmingCharacters(in: .whitespacesAndNewlines) == legacyLSP.1 {
            try? FileManager.default.removeItem(at: lspURL)
        }

        print("""
        [BSP] Created \(bsp.0) for enhanced IDE support. You may
              need to restart your editor for the change to take effect.
        """)
    }
}
