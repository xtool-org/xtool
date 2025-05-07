import Foundation
import XKit
import XToolSupport
import Dependencies

@_documentation(visibility: private)
@main
enum XToolMain {
    static func main() async throws {
        prepareDependencies { dependencies in
            #warning("Improve persistence mechanism")
            // for macOS, we can use KeychainStorage but we need to sign with entitlements.
            // for Windows, we could use dpapi.h or wincred.h.
            // for Linux, maybe use libsecret?
            // see https://github.com/atom/node-keytar
//            #if os(macOS)
//            dependencies.keyValueStorage = KeychainStorage(service: "com.kabiroberai.xtool-keychain.credentials")
//            #endif
        }
        try await XTool.run()
    }
}
