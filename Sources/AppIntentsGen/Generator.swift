import Foundation

/// One-shot façade tying `Scanner` + `Emitter` together. PackLib calls
/// this when it cannot locate Apple's proprietary
/// `appintentsmetadataprocessor` and needs a Linux-native fallback.
public struct Generator: Sendable {

    public init() {}

    /// Scan `sourceRoots`, emit `Metadata.appintents/` into `outputDir`.
    /// Returns the produced `ScannedModule` so callers can log a one-line
    /// summary or assert in tests.
    @discardableResult
    public func generate(
        sourceRoots: [URL],
        inputs: Emitter.Inputs,
        outputDir: URL
    ) throws -> ScannedModule {
        try generate(
            scanRoots: sourceRoots.map { Scanner.ScanRoot(module: inputs.moduleName, url: $0) },
            inputs: inputs,
            outputDir: outputDir
        )
    }

    /// Module-aware variant. Each `ScanRoot` carries the SwiftPM target name
    /// that owns the source files under it; scanned declarations get
    /// stamped with that module so the emitter produces correct mangled
    /// names for cross-module types.
    @discardableResult
    public func generate(
        scanRoots: [Scanner.ScanRoot],
        inputs: Emitter.Inputs,
        outputDir: URL
    ) throws -> ScannedModule {
        let module = try Scanner().scan(roots: scanRoots)
        guard !module.isEmpty else {
            // No AppIntents declared — leave the bundle absent rather
            // than write an empty metadata directory.
            try? FileManager.default.removeItem(at: outputDir)
            return module
        }
        try Emitter().emit(module: module, inputs: inputs, outputDir: outputDir)
        return module
    }
}
