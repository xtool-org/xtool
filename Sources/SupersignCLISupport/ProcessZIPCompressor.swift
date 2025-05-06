import Foundation
import XKit
import Dependencies
import PackLib

extension ZIPCompressor: DependencyKey {
    // TODO: Use `powershell Compress-Archive` and `powershell Expand-Archive` on Windows

    public static let liveValue = ZIPCompressor(
        compress: { dir, progress in
            progress(nil)

            let dest = dir.deletingLastPathComponent().appendingPathComponent("app.ipa")

            let zip = Process()
            zip.executableURL = try await ToolRegistry.locate("zip")
            zip.currentDirectoryURL = dir.deletingLastPathComponent()
            zip.arguments = ["-yqru0", dest.path, "Payload"]
            try await zip.runUntilExit()

            return dest
        },
        decompress: { ipa, directory, progress in
            progress(nil)
            let unzip = Process()
            unzip.executableURL = try await ToolRegistry.locate("unzip")
            unzip.arguments = ["-q", ipa.path, "-d", directory.path]
            try await unzip.runUntilExit()
        }
    )
}
