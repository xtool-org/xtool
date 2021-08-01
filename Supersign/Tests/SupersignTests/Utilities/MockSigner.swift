import Foundation
import SignerSupport

let addMockSigner: () = {
    add_signer(
        "MockSigner",
        { appDir, certData, certLen, privKeyData, privKeyLen, entitlements, numEntitlements, progress, exception in
            exception.initialize(to: strdup("Mock signer not implemented"))
            return 1
        },
        { path, outLen, exception in
            exception.initialize(to: strdup("Mock analyzer not implemented"))
            return nil
        }
    )
}()
