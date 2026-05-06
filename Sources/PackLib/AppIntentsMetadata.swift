import AppIntentsGen
import Foundation
import XUtils

/// Generates the `Metadata.appintents` bundle that iOS Shortcuts uses to
/// discover an app's `AppIntent` / `AppShortcut` declarations.
///
/// xtool's SwiftPM-driven build does not run `appintentsmetadataprocessor`
/// (the proprietary Xcode build phase). Without the bundle, AppIntents
/// compile and run, but Shortcuts/Spotlight/Siri never index them, so the
/// app does not appear in the Shortcuts action picker.
///
/// This step:
///   1. Locates the processor binary (env override -> PATH -> macOS xcrun
///      -> Darwin SDK artifact bundle).
///   2. Collects the per-source `*.appintentsmetadata` outputs that the
///      Swift frontend already emits when `AppIntents` is imported.
///   3. Invokes the processor once per packed product, writing the
///      consolidated `Metadata.appintents` directory into the bundle root.
///
/// If the processor cannot be located the step is skipped with a single
/// warning. Builds without AppIntents are unaffected.
public enum AppIntentsMetadata {

    /// A single (module, source-directory) pair for the native generator.
    /// `module` is the SwiftPM target name (= Swift module name); `url`
    /// is the directory whose `.swift` files belong to that module.
    public struct SourceRoot: Sendable, Equatable {
        public let module: String
        public let url: URL

        public init(module: String, url: URL) {
            self.module = module
            self.url = url
        }
    }

    public struct Inputs: Sendable {
        /// User-visible SPM library / module name (e.g. `iMoonshine`).
        /// Used to namespace synthesised intent identifiers.
        public let moduleName: String

        /// Synthetic builder target name (e.g. `iMoonshine-App`).
        /// Used to locate per-product `.appintentsmetadata` files inside
        /// `.build/<triple>/<config>/<buildModuleName>.build/`.
        public let buildModuleName: String

        public let bundleIdentifier: String
        public let deploymentTarget: String
        public let executableURL: URL
        public let bundleURL: URL
        public let buildDir: URL
        public let sourceRoots: [SourceRoot]

        /// `true` when the product being packed is an app extension (e.g. a
        /// widget appex). Drives `supportedModes` semantics in the emitted
        /// metadata: appex intents get `supportedModes=2`, main-app intents `1`.
        public let isAppExtension: Bool

        public init(
            moduleName: String,
            buildModuleName: String,
            bundleIdentifier: String,
            deploymentTarget: String,
            executableURL: URL,
            bundleURL: URL,
            buildDir: URL,
            sourceRoots: [SourceRoot] = [],
            isAppExtension: Bool = false
        ) {
            self.moduleName = moduleName
            self.buildModuleName = buildModuleName
            self.bundleIdentifier = bundleIdentifier
            self.deploymentTarget = deploymentTarget
            self.executableURL = executableURL
            self.bundleURL = bundleURL
            self.buildDir = buildDir
            self.sourceRoots = sourceRoots
            self.isAppExtension = isAppExtension
        }
    }

    private static let envOverride = "XTOOL_APPINTENTS_PROCESSOR"

    private static let warnedKey = "XTOOL_APPINTENTS_WARNED"

    /// Best-effort search for the proprietary processor.
    static func locateProcessor() async -> URL? {
        if let override = ProcessInfo.processInfo.environment[envOverride],
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        if let path = try? await ToolRegistry.locate("appintentsmetadataprocessor"),
           FileManager.default.isExecutableFile(atPath: path.path) {
            return path
        }

        // Darwin SDK artifact bundle (if a future SDK ships the tool).
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".xtool/SDKs/Darwin.artifactbundle/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor"),
            home.appendingPathComponent(".xtool/SDKs/Darwin.artifactbundle/usr/local/bin/appintentsmetadataprocessor"),
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        return nil
    }

    /// Recursively collects `*.appintentsmetadata` files emitted by swiftc.
    static func collectMetadataFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var matches: [URL] = []
        for case let url as URL in enumerator
        where url.pathExtension == "appintentsmetadata" {
            matches.append(url)
        }
        return matches
    }

    /// Runs the processor for a single product. Returns silently if no
    /// metadata files were emitted (the product does not use AppIntents).
    public static func generate(
        inputs: Inputs,
        triple: String,
        processor: URL
    ) async throws {
        let metadataFiles = collectMetadataFiles(in: inputs.buildDir)
            .filter { $0.path.contains("/\(inputs.buildModuleName).build/")
                   || $0.path.contains("/\(inputs.buildModuleName).swiftmodule/")
                   || $0.deletingPathExtension().lastPathComponent.hasPrefix(inputs.buildModuleName) }

        guard !metadataFiles.isEmpty else { return }

        let outputDir = inputs.bundleURL.appendingPathComponent("Metadata.appintents", isDirectory: true)
        try? FileManager.default.removeItem(at: outputDir)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let listFile = outputDir.appendingPathComponent("source-files.txt")
        let listing = metadataFiles.map(\.path).joined(separator: "\n")
        try Data(listing.utf8).write(to: listFile)
        defer { try? FileManager.default.removeItem(at: listFile) }

        let process = Process()
        process.executableURL = processor
        process.arguments = [
            "--toolchain-dir", processor.deletingLastPathComponent().deletingLastPathComponent().path,
            "--module-name", inputs.moduleName,
            "--target-triple", triple,
            "--binary-file", inputs.executableURL.path,
            "--bundle-identifier", inputs.bundleIdentifier,
            "--output", outputDir.path,
            "--source-files-list", listFile.path,
            "--deployment-target", inputs.deploymentTarget,
            "--platform-family", "iOS",
            "--extract-metadata",
        ]
        process.standardOutput = FileHandle.standardError
        try await process.runUntilExit()
    }

    /// Public alias for tests + diagnostics. Calls into AppIntentsGen.
    public static func runNativeGenerator(inputs: Inputs) throws {
        try generateNative(inputs: inputs)
    }

    /// Linux-native fallback: scan source with SwiftSyntax (`AppIntentsGen`)
    /// and emit a best-effort `Metadata.appintents/` bundle.
    ///
    /// This path produces a smaller, more conservative bundle than Apple's
    /// proprietary processor (no NLU graph, no dynamic-options metadata,
    /// etc.). For the common AppIntent / AppShortcut surface — what most
    /// apps need to be discoverable in Shortcuts — it is sufficient.
    public static func generateNative(inputs: Inputs) throws {
        guard !inputs.sourceRoots.isEmpty else { return }
        let toolchainVersion: String = {
            if let version = ProcessInfo.processInfo.environment["XTOOL_TOOLCHAIN_VERSION"],
               !version.isEmpty {
                return version
            }
            return "swift-unknown"
        }()
        let emitterInputs = Emitter.Inputs(
            bundleIdentifier: inputs.bundleIdentifier,
            moduleName: inputs.moduleName,
            toolchainVersion: toolchainVersion,
            deploymentTarget: inputs.deploymentTarget,
            platformFamily: "iOS",
            isAppExtension: inputs.isAppExtension
        )
        let outputDir = inputs.bundleURL.appendingPathComponent("Metadata.appintents", isDirectory: true)
        let scanRoots = inputs.sourceRoots.map {
            Scanner.ScanRoot(module: $0.module, url: $0.url)
        }
        let module = try Generator().generate(
            scanRoots: scanRoots,
            inputs: emitterInputs,
            outputDir: outputDir
        )
        if module.isEmpty { return }
        notifyNativeOnce(moduleName: inputs.moduleName)
    }

    private static let nativeWarnedKey = "XTOOL_APPINTENTS_NATIVE_NOTIFIED"

    /// Emits a single notice the first time we run the Linux-native
    /// generator in a packing session.
    public static func notifyNativeOnce(moduleName: String) {
        guard ProcessInfo.processInfo.environment[nativeWarnedKey] == nil else { return }
        setenv(nativeWarnedKey, "1", 1)
        FileHandle.standardError.write(Data("""
        note: appintentsmetadataprocessor not found; using xtool-appintents-gen \
        (Linux-native fallback) to produce Metadata.appintents/ for module \
        \(moduleName). Output covers the common AppIntent / AppShortcut \
        surface but does not match Xcode byte-for-byte. Set \(envOverride)=\
        /path/to/appintentsmetadataprocessor for byte-identical output.

        """.utf8))
    }

    /// Emits a single warning across the whole packing session when the
    /// processor is unavailable AND the native fallback is also disabled.
    public static func warnMissingOnce() {
        guard ProcessInfo.processInfo.environment[warnedKey] == nil else { return }
        setenv(warnedKey, "1", 1)
        FileHandle.standardError.write(Data("""
        warning: appintentsmetadataprocessor not found. The packed app will \
        be missing Metadata.appintents and iOS Shortcuts will not index any \
        AppIntent / AppShortcut declarations. Set \(envOverride)=/path/to/\
        appintentsmetadataprocessor (e.g. from an Xcode install) to enable \
        this step.

        """.utf8))
    }
}
