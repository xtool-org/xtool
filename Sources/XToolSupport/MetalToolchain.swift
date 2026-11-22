#if os(macOS)
import Foundation
import Subprocess
import XUtils

/// Xcode's separately downloaded Metal toolchain is not in Swift Build's default search paths.
struct MetalToolchain: Decodable, Sendable {
    let status: String
    let toolchainIdentifier: String
    let toolchainSearchPath: String

    static func installedComponent(from data: Data) -> Self? {
        guard let component = try? JSONDecoder().decode(Self.self, from: data),
              component.status == "installed",
              !component.toolchainIdentifier.isEmpty,
              !component.toolchainSearchPath.isEmpty else {
            return nil
        }
        return component
    }

    static let current = Task<MetalToolchain?, Never> {
        // Query the active Xcode, respecting DEVELOPER_DIR. Older Xcodes may not support
        // -showComponent; absence of a downloadable toolchain must not break non-Metal builds.
        guard let result = try? await Subprocess.run(
            .path("/usr/bin/xcrun"),
            arguments: ["xcodebuild", "-showComponent", "metalToolchain", "-json"],
            output: .data(limit: .max),
            error: .discarded
        ).checkSuccess() else {
            return nil
        }
        return installedComponent(from: result.standardOutput)
    }

    func sessionEnvironment(inheriting environment: [String: String]) -> [String: String] {
        var environment = environment
        let existing = environment["EXTERNAL_TOOLCHAINS_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        environment["EXTERNAL_TOOLCHAINS_DIR"] = [existing, toolchainSearchPath].compactMap { $0 }.joined(separator: ":")
        return environment
    }
}
#endif
