import XPIF
import Foundation
import XUtils
import Subprocess
import Dependencies

/// Uses the installed SwiftPM to resolve a package graph and generate its PIF.
struct SwiftPMPIFDumper: DependencyKey, Sendable {
    static var liveValue: Self { Self() }
    static var testValue: Self { liveValue }

    func dump(packagePath: URL) async throws -> XPIF.Container {
        let pif = try await Subprocess.run(
            .path(d.toolchain.swiftTool),
            arguments: [
                "package",
                "--package-path", packagePath.path,
                "dump-pif",
                "--experimental-build-dylibs-as-frameworks",
            ],
            environment: .inherit.updating([
                // xcrun passes an SDKROOT that messes with our sdk configuration
                "SDKROOT": nil,
            ]),
            platformOptions: .withGracefulShutDown,
            input: .none,
            output: .data(limit: .max),
            error: .xtoolError(),
        )
        .checkSuccess()
        .standardOutput

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
