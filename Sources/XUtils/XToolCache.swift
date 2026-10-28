import Foundation

package enum XToolCache {
    package static var directory: URL {
        let env = ProcessInfo.processInfo.environment
        if let tmpdir = env["XTL_TMPDIR"] ?? env["TMPDIR"] {
            return URL(fileURLWithPath: tmpdir).appendingPathComponent("sh.xtool")
        }
        #if os(Linux)
        // On Linux, /tmp is commonly a tmpfs mount while ~/.swiftpm lives on ext4.
        // Foundation's FileManager.copyItem uses sendfile(2) internally, which returns
        // EINVAL when copying between different filesystem types (e.g. tmpfs → ext4).
        // This causes `swift sdk install` to fail on distros like Linux Mint (#181).
        // Using a cache dir on the home filesystem avoids the cross-fs copy entirely.
        let xdgCache = env["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return xdgCache.appendingPathComponent("xtool")
        #else
        return FileManager.default.temporaryDirectory.appendingPathComponent("sh.xtool")
        #endif
    }
}
