import Foundation
import Supersign

let moduleBundle: Bundle
#if swift(>=5.5) || os(macOS)
moduleBundle = Bundle.module
#else
moduleBundle = Bundle(url: Bundle.main.url(forResource: "Supersign_SupersignCLI", withExtension: "resources")!)!
#endif
let app = moduleBundle.url(forResource: "Supercharge", withExtension: "ipa")!

#warning("Persist manager on Windows/Linux")

// for Windows, we could use dpapi.h or wincred.h.
// for Linux, maybe use libsecret?
// see https://github.com/atom/node-keytar

let signingInfoManager: SigningInfoManager
#if os(macOS)
signingInfoManager = KeyValueSigningInfoManager(
    storage: KeychainStorage(service: "com.kabiroberai.Supercharge-Keychain.credentials")
)
#else
signingInfoManager = MemoryBackedSigningInfoManager()
#endif

try SupersignCLI(app: app, signingInfoManager: signingInfoManager).run()
