import Foundation

struct TemporaryDirectory: ~Copyable {
    private var shouldDelete = true

    let url: URL

    init(name: String) throws {
        self.url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        _delete()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func _delete() {
        try? FileManager.default.removeItem(at: url)
    }

    consuming func persist() -> URL {
        shouldDelete = false
        return url
    }

    consuming func persist(at location: URL) throws {
        try FileManager.default.moveItem(at: url, to: location)
        // we do this after moving, so that if the move fails we clean up
        shouldDelete = false
    }

    deinit {
        if shouldDelete { _delete() }
    }
}

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
