import Testing
import Foundation
import Subprocess
@testable import PackLib

@Test func parsesLLDMajorVersion() {
    #expect(LinkerConfiguration.majorVersion("LLD 23.1.3\n") == 23)
    #expect(LinkerConfiguration.majorVersion("LLD 21.1.6 (compatible with GNU linkers)\n") == 21)
    #expect(LinkerConfiguration.majorVersion("Ubuntu LLD 23.1.0 (compatible with GNU linkers)\n") == 23)
    #expect(LinkerConfiguration.majorVersion("Homebrew LLD 24.0.0\n") == 24)
    #expect(LinkerConfiguration.majorVersion("Ubuntu LLD") == nil)
    #expect(LinkerConfiguration.majorVersion("GNU ld 2.42") == nil)
    #expect(LinkerConfiguration.majorVersion("LLD .") == nil)
    #expect(LinkerConfiguration.majorVersion("") == nil)
}

@Test func overrideToolsetPreservesRelocatableLinkerHandling() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LinkerTests-\(UUID()) ' space")
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("sdk/toolset/bin/ld64.lld")
    let replacement = root.appendingPathComponent("replacement/ld64.lld")
    for (url, text) in [(original, "original"), (replacement, "replacement")] {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf '%s' '\(text)'\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    try Data("test".utf8).write(to: root.appendingPathComponent("sdk/darwin-sdk-version.txt"))
    let sdk = try #require(DarwinSDK(bundle: root.appendingPathComponent("sdk")))
    let toolset = try LinkerConfiguration.writeToolset(
        sdk: sdk, linker: replacement.path, directory: root.appendingPathComponent("cache")
    )
    let definition = try JSONSerialization.jsonObject(with: Data(contentsOf: toolset)) as? [String: Any]
    let selected = try #require((definition?["linker"] as? [String: String])?["path"])
    let finalLink = try await Subprocess.run(.path(.init(selected)), arguments: ["--version"], output: .string(limit: .max))
    let partialLink = try await Subprocess.run(.path(.init(selected)), arguments: ["-r"], output: .string(limit: .max))
    #expect(finalLink.terminationStatus.isSuccess)
    #expect(finalLink.standardOutput == "replacement")
    #expect(partialLink.terminationStatus.isSuccess)
    #expect(partialLink.standardOutput == "original")
}
