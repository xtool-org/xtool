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
                d.out.print("Error copying \(srcURL.path) to \(dstURL.path): \(result.standardError)")
                throw error
            }
            return
        }
        #endif

        try self.copyItem(at: srcURL, to: dstURL)
    }

    /// Copies source to destination _nearly_ atomically.
    /// 
    /// We first perform an intermediate copy into `stagingDir`, then swap
    /// it with `destination`.
    /// 
    /// The operation has a strong-exception guarantee except if the final
    /// swap fails, in which case the destination may be left absent (but this
    /// is less likely than the copy failing).
    public func atomicallyCopyItem(
        at source: URL,
        to destination: URL,
        via stagingDir: URL,
    ) throws {
        let newStaged = stagingDir.appending(path: "new-\(destination.lastPathComponent)")
        let oldStaged = stagingDir.appending(path: "old-\(destination.lastPathComponent)")
        try? removeItem(at: stagingDir)
        try createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? removeItem(at: stagingDir) }
        try copyItem(at: source, to: newStaged)
        do {
            try moveItem(at: destination, to: oldStaged)
        } catch CocoaError.fileNoSuchFile {
            // destination doesn't exist yet, that's fine
        }
        try moveItem(at: newStaged, to: destination)
    }
}

package func stderrPrint(_ message: String, terminator: String = "\n") {
    try? FileHandle.standardError.write(contentsOf: Data("\(message)\(terminator)".utf8))
}
