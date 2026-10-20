import XPIF
import Foundation
import PackLib
import XUtils
import Subprocess
import Dependencies

/// Uses the installed SwiftPM to resolve a package graph and generate its PIF.
struct SwiftPMPIFDumper: DependencyKey, Sendable {
    static var liveValue: Self { Self() }
    static var testValue: Self { liveValue }

    func dump(buildSettings: BuildSettings) async throws -> XPIF.Container {
        let dumpPIFInvocation = try await buildSettings.swiftPMInvocation(
            forTool: "package",
            arguments: ["dump-pif", "--experimental-build-dylibs-as-frameworks"],
        )
        let result = try await Subprocess.run(
            dumpPIFInvocation,
            input: .none,
            output: .data(limit: .max),
            error: .sequence,
        ) { execution in
            for try await contents in execution.standardError {
                @Dependency(\.out) var output
                output.write(
                    contents.bytes.withUnsafeBytes { Data($0) },
                    .stderr,
                    false
                )
            }
        }
        let pif = try result.checkSuccess().standardOutput

        Signposter.track("Dumped PIF")

        return try XPIF.Container(data: pif)
    }
}

extension DependencyValues {
    var swiftPMPIFDumper: SwiftPMPIFDumper {
        get { self[SwiftPMPIFDumper.self] }
        set { self[SwiftPMPIFDumper.self] = newValue }
    }
}
