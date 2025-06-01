import Foundation
#if canImport(Subprocess)
import Subprocess
#endif

extension Data {
    // AsyncBytes is Darwin-only :/

    package init(reading fileHandle: FileHandle) async throws {
        #if canImport(Darwin)
        self = try await fileHandle.bytes.reduce(into: Data()) { $0.append($1) }
        #else
        self = try fileHandle.readToEnd() ?? Data()
        #endif
    }

    package init(reading file: URL) async throws {
        #if canImport(Darwin)
        self = try await file.resourceBytes.reduce(into: Data()) { $0.append($1) }
        #else
        try self.init(contentsOf: file)
        #endif
    }
}

extension FileManager {
    /// Like `copyItem(at:to:)` but allows opting out of preserving the owner
    package func copyItem(
        at srcURL: URL,
        to dstURL: URL,
        preserveOwner: Bool,
    ) async throws {
        // why this is needed: https://github.com/xtool-org/xtool/issues/254

        #if canImport(Subprocess)
        if !preserveOwner {
            let result = try await Subprocess.run(
                .name("cp"),
                arguments: ["-R", srcURL.path, dstURL.path],
                output: .discarded,
                error: .string(limit: .max, encoding: UTF8.self),
            )
            do {
                try result.checkSuccess()
            } catch {
                print("Error copying \(srcURL.path) to \(dstURL.path): \(result.standardError ?? "unknown")")
                throw error
            }
            return
        }
        #endif

        try self.copyItem(at: srcURL, to: dstURL)
    }
}

package func stderrPrint(_ message: String, terminator: String = "\n") {
    try? FileHandle.standardError.write(contentsOf: Data("\(message)\(terminator)".utf8))
}
