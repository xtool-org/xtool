import Foundation
import XUtils

/// Extracts the classic (pre-iOS-17) Developer Disk Image for a specific iOS version out of an
/// Xcode.xip or Xcode.app, reusing `extractXIPRaw` (shared with `SDKBuilder`) for the xip case.
///
/// Real Xcode ships these under `Contents/Developer/Platforms/iPhoneOS.platform/DeviceSupport/
/// <version>/DeveloperDiskImage.dmg(+.signature)` -- a sibling of the `Developer` SDK directory
/// `SDKBuilder` extracts, not something `SDKBuilder`'s own allowlist (`SDKEntry.wanted`) collects.
enum DDIExtractor {
    struct Result {
        let dmg: URL
        let signature: URL
    }

    /// - Parameter versionPrefix: matched against `DeviceSupport` subfolder names via
    ///   `hasPrefix`, e.g. `"16.7"` matches a `"16.7"` folder (Xcode ships DeviceSupport per
    ///   minor version, not per exact patch build).
    static func extract(xcodePath: String, versionPrefix: String, outputDir: URL) async throws -> Result {
        let input = try SDKBuilder.Input(path: xcodePath)

        let appDir: URL
        switch input {
        case .xip(let inputPath):
            let stage = try TemporaryDirectory(name: "DDIExtractStage")
            // unxip doesn't like cooperative cancellation atm so shield it, same as SDKBuilder.
            try await Task {
                try await extractXIPRaw(inputPath: inputPath, outDir: stage.url.path)
            }.value
            try Task.checkCancellation()
            let contents = try FileManager.default.contentsOfDirectory(
                at: stage.url,
                includingPropertiesForKeys: nil
            )
            guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
                throw Console.Error("Unrecognized xip layout (Xcode.app not found)")
            }
            appDir = app
            let result = try locate(appDir: appDir, versionPrefix: versionPrefix, outputDir: outputDir)
            withExtendedLifetime(stage) {}
            return result
        case .app(let appPath):
            appDir = URL(fileURLWithPath: appPath)
            return try locate(appDir: appDir, versionPrefix: versionPrefix, outputDir: outputDir)
        }
    }

    private static func locate(appDir: URL, versionPrefix: String, outputDir: URL) throws -> Result {
        let deviceSupportDir = appDir.appendingPathComponent(
            "Contents/Developer/Platforms/iPhoneOS.platform/DeviceSupport"
        )
        let versions = try FileManager.default.contentsOfDirectory(
            at: deviceSupportDir,
            includingPropertiesForKeys: nil
        )
        guard let match = versions.first(where: { $0.lastPathComponent.hasPrefix(versionPrefix) }) else {
            let available = versions.map(\.lastPathComponent).sorted().joined(separator: ", ")
            throw Console.Error("""
            No DeviceSupport folder matching '\(versionPrefix)' found in this Xcode. \
            Available versions: \(available.isEmpty ? "(none)" : available)
            """)
        }

        let dmgSrc = match.appendingPathComponent("DeveloperDiskImage.dmg")
        let sigSrc = match.appendingPathComponent("DeveloperDiskImage.dmg.signature")
        guard FileManager.default.fileExists(atPath: dmgSrc.path) else {
            throw Console.Error("'\(match.lastPathComponent)' does not contain a DeveloperDiskImage.dmg")
        }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let dmgDest = outputDir.appendingPathComponent("DeveloperDiskImage.dmg")
        let sigDest = outputDir.appendingPathComponent("DeveloperDiskImage.dmg.signature")
        try? FileManager.default.removeItem(at: dmgDest)
        try? FileManager.default.removeItem(at: sigDest)
        try FileManager.default.copyItem(at: dmgSrc, to: dmgDest)
        try FileManager.default.copyItem(at: sigSrc, to: sigDest)

        return Result(dmg: dmgDest, signature: sigDest)
    }
}
