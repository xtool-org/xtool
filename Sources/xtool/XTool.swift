import Foundation
import XKit
import XToolSupport
import Dependencies

@_documentation(visibility: private)
@main
enum XToolMain {
    static func main() async throws {
        prepareDependencies { _ in
            #warning("Improve persistence mechanism")
            // for Windows, we could use dpapi.h or wincred.h.
            // for Linux, maybe use libsecret?
            // see https://github.com/atom/node-keytar
        }
        try await XTool.run()
    }
}
