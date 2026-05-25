import Subprocess
import Version
import XUtils

enum SwiftVersion {}
extension SwiftVersion {
    private static let cached = Task<Version, Error> {
        let outputString: String?
        do {
            outputString = try await Subprocess.run(
                .name("swift"),
                arguments: ["--version"],
                output: .string(limit: .max)
            )
            .checkSuccess()
            .standardOutput
        } catch {
            throw StringError("Failed to obtain Swift version")
        }
        var output = outputString?[...] ?? ""
        if output.hasPrefix("Apple ") {
            output = output.dropFirst("Apple ".count)
        }
        guard output.hasPrefix("Swift version ") else {
            throw StringError("Could not parse Swift version: '\(output)'")
        }
        output = output.dropFirst("Swift version ".count)
        guard let space = output.firstIndex(of: " ") else {
            throw StringError("Could not parse Swift version: '\(output)'")
        }
        output = output[..<space]
        guard let version = Version(tolerant: output) else {
            throw StringError("Could not parse Swift version: '\(output)'")
        }
        return version
    }

    static var current: Version {
        get async throws {
            try await cached.value
        }
    }
}
