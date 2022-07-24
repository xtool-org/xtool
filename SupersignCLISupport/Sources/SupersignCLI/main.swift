import Foundation
import Supersign
import SupersignCLISupport

let moduleBundle: Bundle
#if swift(>=5.5) || os(macOS)
moduleBundle = Bundle.module
#else
moduleBundle = Bundle(url: Bundle.main.url(forResource: "SupersignCLISupport_SupersignCLI", withExtension: "resources")!)!
#endif
let app = moduleBundle.url(forResource: "Supercharge", withExtension: "ipa")!

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

try SupersignCLI.run(configuration: SupersignCLI.Configuration(
    superchargeApp: app,
    storage: storage
))
