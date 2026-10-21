import Foundation
import Subprocess
import XUtils

package enum LinkerConfiguration {
    package static func validate(platform: ApplePlatform, sdk: DarwinSDK) async throws {
        let override = ProcessInfo.processInfo.environment["XTOOL_LD64_LLD"]
        let executable: URL
        if let override {
            guard (override as NSString).isAbsolutePath, FileManager.default.isExecutableFile(atPath: override) else {
                throw StringError("XTOOL_LD64_LLD must name an executable at an absolute path: '\(override)'")
            }
            executable = URL(fileURLWithPath: override)
        } else {
            executable = sdk.bundle.appendingPathComponent("toolset/bin/ld64.lld")
        }
        if platform == .macCatalyst {
            let result = try await Subprocess.run(
                .path(FilePath(executable.path)), arguments: ["--version"], output: .string(limit: .max)
            ).checkSuccess()
            let version = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let major = majorVersion(version), major >= 23 else {
                throw StringError("""
                Mac Catalyst requires LLD 23 or newer on Linux for arm64e SDK reexports. \
                Set XTOOL_LD64_LLD to an updated ld64.lld executable. Found: \(version)
                """)
            }
        }
    }

    package static func toolsetOverride(sdk: DarwinSDK) throws -> URL? {
        guard let override = ProcessInfo.processInfo.environment["XTOOL_LD64_LLD"] else { return nil }
        let key = (sdk.bundle.path + "\n" + override).utf8.reduce(UInt64(14695981039346656037)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
        let directory = try DarwinSDK.swiftPMDirectory().appendingPathComponent("xtool-toolsets/\(String(key, radix: 16))")
        return try writeToolset(sdk: sdk, linker: override, directory: directory)
    }

    static func writeToolset(sdk: DarwinSDK, linker: String, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalBin = sdk.bundle.appendingPathComponent("toolset/bin")
        let wrapper = directory.appendingPathComponent("ld64.lld")
        func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/sh
        set -eu
        for argument do
            if [ "$argument" = "-r" ]; then
                exec \(shellQuote(originalBin.appendingPathComponent("ld64.lld").path)) "$@"
            fi
        done
        exec \(shellQuote(linker)) "$@"
        """
        try Data(script.utf8).write(to: wrapper, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let toolset: [String: Any] = [
            "schemaVersion": "1.0", "rootPath": originalBin.path,
            "linker": ["path": wrapper.path],
            "librarian": ["path": originalBin.appendingPathComponent("llvm-lib").path],
        ]
        let definition = directory.appendingPathComponent("toolset.json")
        try JSONSerialization.data(withJSONObject: toolset, options: .sortedKeys).write(to: definition, options: .atomic)
        return definition
    }

    static func majorVersion(_ output: String) -> Int? {
        let words = output.split(whereSeparator: \.isWhitespace)
        guard let index = words.firstIndex(of: "LLD"), index + 1 < words.endIndex else { return nil }
        return words[index + 1].split(separator: ".").first.flatMap { Int($0) }
    }
}
