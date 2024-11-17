import Foundation
import Supersign
import SupersignCLISupport

let app = Bundle.module.url(forResource: "Supercharge", withExtension: "ipa")!

#warning("Improve persistence on Windows/Linux")

// for Windows, we could use dpapi.h or wincred.h.
// for Linux, maybe use libsecret?
// see https://github.com/atom/node-keytar

let storage: KeyValueStorage
#if os(macOS)
storage = KeychainStorage(service: "com.kabiroberai.Supercharge-Keychain.credentials")
#else
storage = DirectoryStorage(base: URL(fileURLWithPath: "storage", isDirectory: true))
#endif

try await SupersignCLI.run(configuration: SupersignCLI.Configuration(
    superchargeApp: app,
    storage: storage
))
