import AppIntentsGen
import ArgumentParser
import Foundation

@main
struct XToolAppIntentsGen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xtool-appintents-gen",
        abstract: "Generate a Metadata.appintents bundle from Swift sources without needing Xcode.",
        discussion: """
        Linux-native fallback for Apple's appintentsmetadataprocessor. \
        Walks the supplied source roots with SwiftSyntax, extracts every \
        AppIntent / AppShortcutsProvider / AppEntity / AppEnum declaration, \
        and writes Metadata.appintents/extract.actionsdata, version.json, \
        and en.lproj/nlu.appintents into the target directory.
        """
    )

    @Option(name: .shortAndLong, help: "Bundle identifier for the produced app or appex.")
    var bundleIdentifier: String

    @Option(name: .shortAndLong, help: "Module name. Used as the namespace for synthesised type identifiers.")
    var moduleName: String

    @Option(name: .long, help: "Minimum iOS deployment target, e.g. 17.0.")
    var deploymentTarget: String = "17.0"

    @Option(name: .long, help: "Platform family written to version.json.")
    var platformFamily: String = "iOS"

    @Option(name: .long, help: "Toolchain version stamp, e.g. swift-6.3.1.")
    var toolchainVersion: String = "swift-unknown"

    @Option(name: .long, parsing: .upToNextOption, help: "One or more directories to scan recursively for *.swift files. Use the form '<module>=<path>' to attribute a directory to a specific Swift module; a bare path falls back to --module-name.")
    var sourceRoot: [String] = []

    @Option(name: .shortAndLong, help: "Path of the Metadata.appintents directory to write.")
    var output: String

    func run() async throws {
        let inputs = Emitter.Inputs(
            bundleIdentifier: bundleIdentifier,
            moduleName: moduleName,
            toolchainVersion: toolchainVersion,
            deploymentTarget: deploymentTarget,
            platformFamily: platformFamily
        )
        let scanRoots: [AppIntentsGen.Scanner.ScanRoot] = sourceRoot.map { entry in
            if let eq = entry.firstIndex(of: "=") {
                let module = String(entry[..<eq])
                let path = String(entry[entry.index(after: eq)...])
                return AppIntentsGen.Scanner.ScanRoot(
                    module: module.isEmpty ? moduleName : module,
                    url: URL(fileURLWithPath: path)
                )
            }
            return AppIntentsGen.Scanner.ScanRoot(module: moduleName, url: URL(fileURLWithPath: entry))
        }
        let outputDir = URL(fileURLWithPath: output)
        let module = try Generator().generate(
            scanRoots: scanRoots,
            inputs: inputs,
            outputDir: outputDir
        )
        FileHandle.standardError.write(Data("""
        xtool-appintents-gen: emitted \(module.intents.count) intent(s), \
        \(module.shortcutsProviders.flatMap(\.shortcuts).count) app shortcut(s), \
        \(module.entities.count) entity(ies), \(module.enums.count) enum(s) \
        into \(outputDir.path)\n
        """.utf8))
    }
}
