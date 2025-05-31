import Foundation
import SignerSupport

let addMockSigner: () = {
    add_signer(
        "MockSigner",
        { _, _, _, _, _, _, _, _, _, exception in
            exception.initialize(to: strdup("Mock signer not implemented"))
            return 1
        },
        { _, _, exception in
            exception.initialize(to: strdup("Mock analyzer not implemented"))
            return nil
        }
    )
}()
