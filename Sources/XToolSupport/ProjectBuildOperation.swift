import XCLIUtils
import Foundation
import SwiftBuild
import XUtils

struct ProjectBuildResult: Sendable {
    var url: URL
    var bundleID: String
}

struct ProjectBuildOperation {
    let buildCoordinator: BuildCoordinator
    let verbose: Bool

    func run() async throws -> ProjectBuildResult {
        let (_, bundleID, installedProduct) = try await buildCoordinator.mainProductDetails()

        Signposter.track("Starting build")

        let operation = try await buildCoordinator.createBuildOperation()
        try await withTaskCancellationHandler {
            for await event in try await operation.start() {
                printEvent(event)
            }
            await operation.waitForCompletion()
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
        switch operation.state {
        case .succeeded:
            break
        case .requested, .running:
            throw Console.Error("Internal error: build operation did not complete")
        case .aborted, .cancelled:
            throw CancellationError()
        case .failed:
            d.out.print()
            throw Console.Error("Build failed")
        }

        Signposter.track("Build completed")

        let xtoolDir = URL(filePath: "xtool").absoluteURL
        let output = xtoolDir.appending(path: installedProduct.lastPathComponent)
        let staging = xtoolDir.appending(path: ".xtool-tmp/copy-stage")
        try FileManager.default.atomicallyCopyItem(at: installedProduct, to: output, via: staging)

        if verbose {
            d.out.print("Build completed.")
        } else {
            printProgress(100, targetName: nil, message: "Build completed.\n")
        }

        return ProjectBuildResult(url: output, bundleID: bundleID)
    }

    private func printEvent(_ event: SwiftBuildMessage) {
        if verbose {
            d.out.print("\(event)")
        } else {
            switch event {
            case .diagnostic(let diagnostic):
                switch diagnostic.kind {
                case .note, .remark: return
                case .warning, .error: break
                }
                d.out.print("""
                \n\(diagnostic.kind.rawValue): \
                \(diagnostic.location.userDescription.map { "\($0): " } ?? "")\
                \(diagnostic.message)
                """)
            case .didUpdateProgress(let progress):
                printProgress(
                    progress.percentComplete,
                    targetName: progress.targetName ?? "Building",
                    message: progress.message,
                )
            default:
                break
            }
        }
    }

    private func printProgress(_ percentComplete: Double, targetName: String?, message: String) {
        let progress = percentComplete == -1 ? "0%" : "\(String(format: "%.2f", percentComplete))%"
        d.out.print("\u{1B}[2K\r[\(progress)] \(targetName.map { "\($0) " } ?? "")\(message)", terminator: "")
    }
}

fileprivate extension SwiftBuild.SwiftBuildMessage.DiagnosticInfo.Location {
    var userDescription: String? {
        switch self {
        case .path(let path, let fileLocation):
            switch fileLocation {
            case .textual(let line, let column):
                var description = "\(path):\(line)"
                if let column { description += ":\(column)" }
                return description
            case .object(let identifier):
                return "\(path):\(identifier)"
            case .none:
                return path
            }

        case .buildSettings(let names):
            return names.joined(separator: ", ")

        case .buildFiles(let buildFiles, let targetGUID):
            return "\(targetGUID): " + buildFiles.map { String(describing: $0) }.joined(separator: ", ")

        case .unknown:
            return nil
        }
    }
}
