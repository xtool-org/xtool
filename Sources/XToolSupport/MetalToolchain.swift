#if os(macOS)
import Foundation
import Subprocess
import XUtils

/// Xcode's separately downloaded Metal toolchain is not in Swift Build's default search paths.
struct MetalToolchain: Sendable {
    let toolchainIdentifier: String
    let toolchainSearchPath: String

    private struct Component: Decodable {
        let status: String
        let toolchainIdentifier: String
        let toolchainSearchPath: String
    }

    static func installedComponent(from data: Data) -> Self? {
        guard let component = try? JSONDecoder().decode(Component.self, from: data),
              component.status == "installed",
              !component.toolchainIdentifier.isEmpty,
              !component.toolchainSearchPath.isEmpty else {
            return nil
        }
        return Self(
            toolchainIdentifier: component.toolchainIdentifier,
            toolchainSearchPath: component.toolchainSearchPath
        )
    }

    /// Started on first access. Touch this early so the query overlaps other startup work.
    static let current = Task<MetalToolchain?, Never> {
        await withTaskGroup(of: MetalToolchain?.self) { group in
            group.addTask { await query() }
            // The query sits on every build's critical path; never let it stall one.
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func query() async -> MetalToolchain? {
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

    /// Appends this toolchain's search directory to an `EXTERNAL_TOOLCHAINS_DIR` value, keeping existing entries.
    func externalToolchainsDir(appendingTo existing: String?) -> String {
        let paths = (existing ?? "").split(separator: ":").map(String.init)
        return (paths.contains(toolchainSearchPath) ? paths : paths + [toolchainSearchPath]).joined(separator: ":")
    }

    func sessionEnvironment(inheriting environment: [String: String]) -> [String: String] {
        var environment = environment
        environment["EXTERNAL_TOOLCHAINS_DIR"] = externalToolchainsDir(appendingTo: environment["EXTERNAL_TOOLCHAINS_DIR"])
        return environment
    }

    /// Swift Build prefers a process-level `EXTERNAL_TOOLCHAINS_DIR` over the session environment's,
    /// even when empty, and snapshots the process environment on first use. When the process defines
    /// the variable, extend it in place; call this before the build service starts.
    func extendProcessEnvironment() {
        guard let existing = ProcessInfo.processInfo.environment["EXTERNAL_TOOLCHAINS_DIR"] else { return }
        setenv("EXTERNAL_TOOLCHAINS_DIR", externalToolchainsDir(appendingTo: existing), 1)
    }
}
#endif
