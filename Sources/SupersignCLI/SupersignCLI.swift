import Foundation
import Supersign
import SupersignCLISupport
import Dependencies

@main enum SupersignCLIMain {
    static func main() async throws {
        try await SupersignCLI.run()
    }
}

#warning("Improve persistence mechanism")

// for macOS, we can use KeychainStorage but we need to sign with entitlements.
// for Windows, we could use dpapi.h or wincred.h.
// for Linux, maybe use libsecret?
// see https://github.com/atom/node-keytar
extension KeyValueStorageDependencyKey: DependencyKey {
    public static let liveValue: KeyValueStorage = {
//        #if os(macOS)
//        KeychainStorage(service: "com.kabiroberai.Supercharge-Keychain.credentials")
//        #else
        DirectoryStorage(
            base: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/Supercharge/data")
        )
//        #endif
    }()
}
