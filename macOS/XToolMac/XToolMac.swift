import Foundation
import Dependencies
import XToolSupport
import XKit

@main enum XToolMacMain {
    static func main() async throws {
        // the bin/xtool script invokes us with this env var, allowing us to
        // detect command-line invocations vs a UI app launch
        if ProcessInfo.processInfo.environment["XTL_CLI"] == "1" {
            try await runXTool()
        } else {
            XToolMacUI.main()
        }
    }

    private static func runXTool() async throws {
        try await withDependencies { d in
            #if HAS_TEAM
            d.keyValueStorage = KeychainStorage(service: "sh.xtool.keychain.credentials")
            #endif
        } operation: {
            try await XTool.run()
        }
    }
}
