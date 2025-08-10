import Foundation

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

package func stderrPrint(_ message: String, terminator: String = "\n") {
    try? FileHandle.standardError.write(contentsOf: Data("\(message)\(terminator)".utf8))
}
