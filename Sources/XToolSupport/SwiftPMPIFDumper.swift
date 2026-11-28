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

        return try XPIF.Container(data: pif).relocatingPluginTools()
    }
}

extension XPIF.Container {
    /// Fixes up build tool plugin command paths.
    /// 
    /// `swift package dump-pif` hardcodes absolute paths in ./.build/out, but our DerivedData
    /// is actually in ./xtool. Rewrite accordingly.
    func relocatingPluginTools() -> Self {
        let products = URL(filePath: workspace.path, directoryHint: .isDirectory)
            .appending(path: ".build/out/Products/Debug")
            .path

        func relocate(_ value: String) -> String {
            // the directory is the configuration + the host's suffix, which is empty on macOS
            // (e.g. `Debug`, `Debug-linux-x86_64`)
            value
                .replacing("\(products)/", with: "$(BUILD_DIR)/$(CONFIGURATION)/")
                .replacing("\(products)-", with: "$(BUILD_DIR)/$(CONFIGURATION)-")
        }

        var container = self
        container.workspace.projects = workspace.projects.map { project in
            var project = project
            project.targets = project.targets.map { target in
                var target = target
                target.common.customTasks = target.common.customTasks.map { task in
                    var task = task
                    task.commandLine = task.commandLine.map(relocate)
                    task.environment = task.environment.map { .init(relocate($0.first), relocate($0.second)) }
                    task.workingDirectory = task.workingDirectory.map(relocate)
                    task.inputFilePaths = task.inputFilePaths.map(relocate)
                    task.outputFilePaths = task.outputFilePaths.map(relocate)
                    return task
                }
                return target
            }
            return project
        }
        return container
    }
}

extension DependencyValues {
    var swiftPMPIFDumper: SwiftPMPIFDumper {
        get { self[SwiftPMPIFDumper.self] }
        set { self[SwiftPMPIFDumper.self] = newValue }
    }
}
