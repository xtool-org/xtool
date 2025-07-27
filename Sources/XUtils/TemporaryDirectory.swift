import Foundation

package struct TemporaryDirectory: ~Copyable {
    private static let debugTmp = ProcessInfo.processInfo.environment["XTL_DEBUG_TMP"] != nil

    private var shouldDelete: Bool
    package let url: URL

    package init(name: String) throws {
        do {
            let basename = name.replacingOccurrences(of: ".", with: "_")
            self.url = try TemporaryDirectoryRoot.shared.url
                // ensures uniqueness
                .appendingPathComponent("tmp-\(basename)-\(UUID().uuidString)")
                .appendingPathComponent(name, isDirectory: true)
            self.shouldDelete = true
        } catch {
            // non-copyable types can't be partially initialized so we need a stub value
            self.url = URL(fileURLWithPath: "")
            self.shouldDelete = false
            throw error
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        if Self.debugTmp {
            stderrPrint("Created TemporaryDirectory: \(url.path)")
        }
    }

    private func _delete() {
        guard !Self.debugTmp else { return }
        try? FileManager.default.removeItem(at: url)
    }

    package consuming func persist(at location: URL) throws {
        try FileManager.default.moveItem(at: url, to: location)
        // we do this after moving, so that if the move fails we clean up
        shouldDelete = false
    }

    deinit {
        if shouldDelete { _delete() }
    }
}

private struct TemporaryDirectoryRoot {
    static let shared = TemporaryDirectoryRoot()

    private let _url: Result<URL, Errors>
    var url: URL {
        get throws(Errors) {
            try _url.get()
        }
    }

    private init() {
        let base: URL
        let env = ProcessInfo.processInfo.environment
        if let tmpdir = env["XTL_TMPDIR"] ?? env["TMPDIR"] {
            base = URL(fileURLWithPath: tmpdir)
        } else {
            base = FileManager.default.temporaryDirectory
        }

        let url = base.appendingPathComponent("sh.xtool")
        try? FileManager.default.removeItem(at: url)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            self._url = .failure(Errors.tmpdirCreationFailed(url, error))
            return
        }
        self._url = .success(url)
    }

    enum Errors: Error, CustomStringConvertible {
        case tmpdirCreationFailed(URL, Error)

        var description: String {
            switch self {
            case let .tmpdirCreationFailed(url, error):
                "Could not create temporary directory at '\(url.path)': \(error)"
            }
        }
    }
}
