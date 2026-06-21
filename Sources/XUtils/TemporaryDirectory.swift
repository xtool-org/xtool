import Foundation

package struct TemporaryDirectory: ~Copyable {
    private static let debugTmp = ProcessInfo.processInfo.environment["XTL_DEBUG_TMP"] != nil

    private var shouldDelete: Bool
    package let url: URL

    /// Prepares a fresh tmpdir root.
    ///
    /// Optional, but try calling this at launch to clean up old resources.
    package static func prepare() {
        _ = TemporaryDirectoryRoot.shared
    }

    /// Creates a temporary directory where `lastPathComponent` is exactly `name`.
    ///
    /// The directory is deleted on deinit or (if the object never deinits) on next launch.
    /// To save the contents, move them elsewhere with ``persist(at:)``.
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
        let url: URL
        let env = ProcessInfo.processInfo.environment
        if let tmpdir = env["XTL_TMPDIR"] ?? env["TMPDIR"] {
            url = URL(fileURLWithPath: tmpdir).appendingPathComponent("sh.xtool")
        } else {
            #if os(Linux)
            // On Linux, /tmp is commonly a tmpfs mount while ~/.swiftpm lives on ext4.
            // Foundation's FileManager.copyItem uses sendfile(2) internally, which returns
            // EINVAL when copying between different filesystem types (e.g. tmpfs → ext4).
            // This causes `swift sdk install` to fail on distros like Linux Mint (#181).
            // Using a cache dir on the home filesystem avoids the cross-fs copy entirely.
            let xdgCache = env["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
            url = xdgCache.appendingPathComponent("xtool")
            #else
            url = FileManager.default.temporaryDirectory.appendingPathComponent("sh.xtool")
            #endif
        }

        Self.pruneOrphans(in: url)

        self._url = Result {
            let childDir = try Self.claimDirectory(in: url)
            try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)
            return childDir
        }
        .mapError { $0 as? Errors ?? .tmpdirCreationFailed(url, $0) }
    }

    private static func claimDirectory(in url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

//        #if os(macOS)
//        let random = UUID().uuidString
//        let lockFile = url.appending(path: "\(random).lock")
//        print("Locking")
//        _ = try FileDescriptor.open(FilePath(lockFile.path), .readWrite, options: [.create, .exclusiveLock])
//        print("Locked")
//        return url.appending(path: random)
//        #else
        for _ in 0..<10 {
            let random = UUID().uuidString
            let lockFile = url.appending(path: "\(random).lock")
            FileManager.default.createFile(atPath: lockFile.path, contents: nil)
            let fd = try FileDescriptor.open(FilePath(lockFile.path), .writeOnly, options: [])
            guard try fd.tryLock(mode: .exclusive) else {
                // someone else raced us and claimed the right to prune between when we created the file and
                // when we tried to lock it
                continue
            }
            return url.appending(path: random)
        }
        throw Errors.tmpdirClaimFailed(url)
//        #endif
    }

    private static func pruneOrphans(in url: URL) {
        guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            else { return }
        for lock in children {
            do {
                let basename = lock.lastPathComponent
                guard basename.hasSuffix(".lock") && basename != ".lock" else { continue }
                let lockFD = try FileDescriptor.open(FilePath(lock.path), .readWrite)
                defer { try? lockFD.close() }
                if try lockFD.tryLock(mode: .exclusive) {
                    // we must remove the directory first. if we instead removed the lock first,
                    // we could be killed after the lock was removed but before the dir was
                    // removed and therefore leave it hanging around.
                    do {
                        try FileManager.default.removeItem(at: lock.deletingPathExtension())
                    } catch CocoaError.fileNoSuchFile {
                        // pass
                    }
                    try FileManager.default.removeItem(at: lock)
                }
            } catch {
                // continue
            }
        }
    }

    enum Errors: Error, CustomStringConvertible {
        case tmpdirCreationFailed(URL, Error)
        case tmpdirClaimFailed(URL)

        var description: String {
            switch self {
            case let .tmpdirCreationFailed(url, error):
                "Could not create temporary directory in '\(url.path)': \(error)"
            case let .tmpdirClaimFailed(url):
                "Could not claim temporary directory in '\(url.path)'"
            }
        }
    }
}
