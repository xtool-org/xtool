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
        try await withDependencies {
            $0.keyValueStorage = KeychainStorage(service: "sh.xtool.keychain.credentials")
        } operation: {
            try await XTool.run()
        }
    }
}
