import Foundation
import XKit
import Dependencies
import PackLib
import Subprocess
import XUtils

extension ZIPCompressor: DependencyKey {
    // TODO: Use `powershell Compress-Archive` and `powershell Expand-Archive` on Windows

    public static let liveValue = ZIPCompressor(
        compress: { dir, progress in
            progress(nil)

            let dest = dir.deletingLastPathComponent().appendingPathComponent("app.ipa")

            try await Subprocess.run(
                .name("zip"),
                arguments: ["-yqru0", dest.path, dir.lastPathComponent],
                workingDirectory: FilePath(dir.deletingLastPathComponent()),
                output: .discarded,
            ).checkSuccess()

            return dest
        },
        decompress: { ipa, directory, progress in
            progress(nil)

            try await Subprocess.run(
                .name("unzip"),
                arguments: ["-q", ipa.path, "-d", directory.path],
                output: .discarded,
            ).checkSuccess()
        }
    )
}
