//
//  File.swift
//  Supersign
//
//  Created by Kabir Oberai on 23/12/24.
//

import Foundation
import Supersign
import Dependencies

extension ZIPCompressor: DependencyKey {
    // TODO: Use `powershell Compress-Archive` and `powershell Expand-Archive` on Windows

    public static let liveValue = ZIPCompressor(
        compress: { dir, progress in
            progress(nil)

            let dest = dir.deletingLastPathComponent().appendingPathComponent("app.ipa")

            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            zip.currentDirectoryURL = dir.deletingLastPathComponent()
            zip.arguments = ["zip", "-yqru0", dest.path, "Payload"]
            try zip.run()
            await zip.waitForExit()
            guard zip.terminationStatus == 0 else {
                throw ZIPCompressorError.compressionFailed
            }

            return dest
        },
        decompress: { ipa, directory, progress in
            progress(nil)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            unzip.arguments = ["unzip", "-q", ipa.path, "-d", directory.path]
            try unzip.run()
            await unzip.waitForExit()
            guard unzip.terminationStatus == 0 else {
                throw ZIPCompressorError.decompressionFailed
            }
        }
    )
}

enum ZIPCompressorError: Error {
    case compressionFailed
    case decompressionFailed
}
