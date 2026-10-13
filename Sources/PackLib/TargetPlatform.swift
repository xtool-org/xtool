import Foundation
import XUtils

/// Target identity is independent of the host and of the build backend.
public enum TargetPlatform: String, Codable, Sendable, CaseIterable {
    case iOS = "ios"
    case iOSSimulator = "ios-simulator"
    case macOS = "macos"

    public var minimumDeploymentTarget: String {
        switch self {
        case .iOS, .iOSSimulator: "13.0"
        case .macOS: "15.0"
        }
    }

    public var packagePlatformName: String {
        self == .macOS ? "macos" : "ios"
    }

    public var supportedPlatform: String {
        switch self {
        case .iOS: "iPhoneOS"
        case .iOSSimulator: "iPhoneSimulator"
        case .macOS: "MacOSX"
        }
    }
}

/// Parse only supported Apple targets; never infer the target from the host.
public struct TargetTriple: Sendable, Equatable {
    public let architecture: String
    public let platform: TargetPlatform
    public let deploymentTarget: String?

    public init(_ triple: String) throws {
        let parts = triple.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard (3...4).contains(parts.count), parts[1] == "apple" else {
            throw StringError("Unsupported target triple: \(triple)")
        }
        let os = String(parts[2].prefix { !$0.isNumber })
        let version = String(parts[2].dropFirst(os.count))
        switch (os, parts.count == 4 ? parts[3] : "") {
        case ("ios", ""): platform = .iOS
        case ("ios", "simulator"): platform = .iOSSimulator
        case ("macos", ""), ("macosx", ""): platform = .macOS
        default: throw StringError("Unsupported target triple: \(triple)")
        }
        architecture = parts[0]
        let supported = platform == .iOS ? ["arm64"] : ["arm64", "x86_64"]
        guard supported.contains(architecture) else {
            throw StringError("Unsupported architecture '\(architecture)' for \(platform.rawValue)")
        }
        if !version.isEmpty { try Self.validateVersion(version) }
        deploymentTarget = version.isEmpty ? nil : version
    }

    static func validateVersion(_ value: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else {
            throw StringError("Invalid deployment target: \(value)")
        }
    }
}

/// Resolve once, then share this value with planning, compilation, assembly, and signing.
public struct ResolvedTarget: Codable, Sendable, Equatable {
    public static let defaultTriple = "arm64-apple-ios"

    public let triple: String
    public let platform: TargetPlatform
    public let architecture: String
    public let deploymentTarget: String

    /// Triple precedence: CLI > schema > iOS default.
    /// Deployment precedence: selected triple's version > schema > package > platform minimum.
    /// A selected triple cannot lower an explicit schema/package minimum.
    public static func resolve(
        cliTarget: String? = nil,
        schema: PackSchema = .default,
        packageDeploymentTargets: [String: String] = [:]
    ) throws -> Self {
        let triple = cliTarget ?? schema.target ?? defaultTriple
        let parsed = try TargetTriple(triple)
        let packageMinimum = packageDeploymentTargets[parsed.platform.packagePlatformName]
        let deployment = parsed.deploymentTarget ?? schema.deploymentTarget
            ?? packageMinimum ?? parsed.platform.minimumDeploymentTarget
        try TargetTriple.validateVersion(deployment)
        for minimum in [schema.deploymentTarget, packageMinimum, parsed.platform.minimumDeploymentTarget].compactMap({ $0 }) {
            try TargetTriple.validateVersion(minimum)
            guard !version(deployment, isBelow: minimum) else {
                throw StringError("Deployment target \(deployment) is below required minimum \(minimum)")
            }
        }
        try schema.validate(for: parsed.platform)
        return Self(
            triple: triple,
            platform: parsed.platform,
            architecture: parsed.architecture,
            deploymentTarget: deployment
        )
    }

    private static func version(_ value: String, isBelow minimum: String) -> Bool {
        let lhs = value.split(separator: ".").map { Int($0) ?? Int.max }
        let rhs = minimum.split(separator: ".").map { Int($0) ?? Int.max }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// SDK identity remains `triple`; compiler invocations use this versioned target.
    public var compilerTriple: String {
        switch platform {
        case .iOS: "\(architecture)-apple-ios\(deploymentTarget)"
        case .iOSSimulator: "\(architecture)-apple-ios\(deploymentTarget)-simulator"
        case .macOS: "\(architecture)-apple-macosx\(deploymentTarget)"
        }
    }
}
