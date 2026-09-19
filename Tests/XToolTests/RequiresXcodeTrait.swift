import Foundation
import Testing
import Subprocess

enum TestXcode {
    /// A path to a copy of Xcode.app.
    /// 
    /// Tests that use this must be annotated with `Trait.requiresXcode`.
    static func current(sourceLocation: SourceLocation = #_sourceLocation) -> URL {
        guard let url = TestXcode._current else {
            Issue.record(
                "TestXcode.current was used without Trait.requiresXcode()",
                sourceLocation: sourceLocation
            )
            return URL(filePath: "/dev/null")
        }
        return url
    }

    @TaskLocal fileprivate static var _current: URL?

    fileprivate static let resolved = Task<URL?, Error> {
        if let xcode = ProcessInfo.processInfo.environment["XTL_TEST_XCODE_APP"], !xcode.isEmpty {
            return URL(filePath: xcode)
        }
        #if os(macOS)
        if
            let output = try await Subprocess.run(
                .path("/usr/bin/xcode-select"),
                arguments: ["-p"],
                output: .string(limit: .max, encoding: UTF8.self),
            ).standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
            output.hasSuffix(".app/Contents/Developer") {
            return URL(filePath: output).deletingLastPathComponent().deletingLastPathComponent()
        }
        #endif
        let candidate = URL(filePath: "/usr/local/share/Xcode.app")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }
}

struct RequiresXcodeTrait: TestTrait, SuiteTrait, TestScoping {
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: () async throws -> Void
    ) async throws {
        guard let xcode = try? await TestXcode.resolved.value else {
            try Test.cancel("Could not resolve Xcode.app path. Set XTL_TEST_XCODE_APP.")
        }
        return try await TestXcode.$_current.withValue(xcode) {
            try await function()
        }
    }
}

extension Trait where Self == RequiresXcodeTrait {
    static var requiresXcode: Self {
        Self()
    }
}
