import Foundation
import XKit
import XToolSupport
import Dependencies

@_documentation(visibility: private)
@main
enum XToolMain {
    static func main() async throws {
        // `stdout` is fully block-buffered (not line-buffered) whenever it isn't a TTY -- e.g.
        // whenever output is redirected to a file/pipe, which is exactly when a hung or killed
        // process's *last* lines matter most for diagnosis. Without this, those buffered lines
        // are silently lost on a SIGTERM/crash, and concurrent writers can interleave mid-line
        // (confirmed against real hardware, this session: a killed `xtool test --repeat` run
        // produced a log with two lines spliced together character-by-character).
        setvbuf(stdoutSafe, nil, _IOLBF, 0)

        prepareDependencies { _ in
            #warning("Improve persistence mechanism")
            // for Windows, we could use dpapi.h or wincred.h.
            // for Linux, maybe use libsecret?
            // see https://github.com/atom/node-keytar
        }
        try await XTool.run()
    }
}
