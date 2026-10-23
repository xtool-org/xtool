import Foundation

package enum XToolCache {
    package static var directory: URL {
        let env = ProcessInfo.processInfo.environment
        if let tmpdir = env["XTL_TMPDIR"] {
            return URL(fileURLWithPath: tmpdir).appendingPathComponent("sh.xtool")
        }
        #if os(Linux)
        let xdgCache: URL
        if let xdgCachePath = env["XDG_CACHE_HOME"],
           (xdgCachePath as NSString).isAbsolutePath {
            xdgCache = URL(filePath: xdgCachePath)
        } else {
            xdgCache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        }
        return xdgCache.appending(component: "xtool")
        #else
        return URL.cachesDirectory.appending(component: "sh.xtool")
        #endif
    }
}
