import Subprocess
import XUtils

public struct SwiftVersion: Sendable, Comparable, Hashable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.tuple < rhs.tuple
    }

    fileprivate var tuple: (Int, Int, Int) {
        (major, minor, patch)
    }
}

extension SwiftVersion {
    public var supportsSwiftBuild: Bool {
        self >= SwiftVersion(6, 4)
    }
}

extension SwiftVersion: LosslessStringConvertible, CustomStringConvertible {
    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public init?(_ description: String) {
        // inverse of https://github.com/swiftlang/swift/blob/896191b38/lib/Basic/Version.cpp#L266

        var output = description[...]
        if output.hasPrefix("Apple ") {
            output = output.dropFirst("Apple ".count)
        }
        if output.hasPrefix("Swift version ") {
            output = output.dropFirst("Swift version ".count)
            output = output.prefix { !$0.isWhitespace }
        }
        let isDev = output.hasSuffix("-dev")
        if isDev { output = output.dropLast("-dev".count) }

        let parts = output.split(separator: ".")
        var numericParts = parts.compactMap { Int($0) }
        guard parts.count == numericParts.count else {
            return nil
        }

        switch numericParts.count {
        case 2: numericParts.append(0)
        case 3: break
        default: return nil
        }

        self.init(numericParts[0], numericParts[1], numericParts[2])
    }
}

extension SwiftVersion {
    private static let cached = Task<Self, Error> {
        let outputString: String?
        do {
            outputString = try await Subprocess.run(
                .path(try await BuildSettings.swiftURL()),
                arguments: ["--version"],
                output: .string(limit: .max)
            )
            .checkSuccess()
            .standardOutput
        } catch {
            throw StringError("Failed to obtain Swift version")
        }

        let output = outputString ?? ""
        guard let version = Self(output) else {
            throw StringError("Could not parse Swift version: '\(output)'")
        }
        return version
    }

    public static var current: Self {
        get async throws {
            try await cached.value
        }
    }
}
