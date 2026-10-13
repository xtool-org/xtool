import ArgumentParser
import Dependencies
import Foundation
import Testing
@testable import PackLib
@testable import XToolSupport

struct MacArtifactTests {
    static func fixture(at bundle: URL) throws {
        let directory = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleExecutable": "App", "CFBundlePackageType": "APPL",
                                   "CFBundleIdentifier": "test.App", "LSMinimumSystemVersion": "15.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try binary().write(to: directory.appendingPathComponent("App"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("App").path)
    }

    static func binary(dependency: String? = nil, type: UInt32 = 2, rpath: String? = nil) -> Data {
        func words(_ values: [UInt32]) -> Data {
            values.reduce(into: Data()) { result, value in
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
            }
        }
        var commands = words([0x32, 24, 1, 0x000f0000, 0x001a0000, 0])
        var count: UInt32 = 1
        for (command, path) in [(UInt32(0xc), dependency), (UInt32(0x8000001c), rpath)] {
            guard let path else { continue }
            let header: UInt32 = command == 0xc ? 24 : 12
            var string = Data(path.utf8) + Data([0])
            while (Int(header) + string.count) % 8 != 0 { string.append(0) }
            commands += words([command, header + UInt32(string.count), header])
            if header == 24 { commands += words([0, 0, 0]) }
            commands += string
            count += 1
        }
        return words([0xfeedfacf, 0x0100000c, 0, type, count, UInt32(commands.count), 0, 0]) + commands
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func handoff(at root: URL) throws -> URL {
        let bundle = root.appendingPathComponent("App.app")
        try Self.fixture(at: bundle)
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        let entitlements = root.appendingPathComponent("App.entitlements")
        try PropertyListSerialization.data(fromPropertyList: ["test.flag": true], format: .xml, options: 0).write(to: entitlements)
        let app = Plan.Product(target: target, type: .application, product: "App", bundleID: "test.App",
                               infoPlist: [:], resources: [], entitlementsPath: entitlements.path)
        let manifest = try DeferredSigningHandoff.write(plan: Plan(target: target, app: app), bundle: bundle, sourceDirectory: root)
        try MacArtifact.write(bundle: bundle, signingManifest: manifest)
        return bundle
    }

    @Test func relocatedHandoffVerifiesAndDetectsResourceMutation() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try handoff(at: source)
        let moved = directory.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: source, to: moved)
        let app = moved.appendingPathComponent("App.app")
        try MacArtifact.verify(bundle: app)
        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/extra.txt"))
        #expect(throws: (any Error).self) { try MacArtifact.verify(bundle: app) }
    }

    @Test func entitlementMutationIsDetected() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try handoff(at: directory)
        let manifest = try JSONDecoder().decode(DeferredSigningManifest.self,
                                                from: Data(contentsOf: directory.appendingPathComponent("App.signing.json")))
        let input = try #require(manifest.products.first?.entitlementsPath)
        try Data("changed".utf8).write(to: directory.appendingPathComponent(input))
        #expect(throws: (any Error).self) { try MacArtifact.verify(bundle: app) }
    }

    @Test func executableBitMutationIsDetected() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try handoff(at: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: app.appendingPathComponent("Contents/MacOS/App").path)
        #expect(throws: (any Error).self) { try MacArtifact.verify(bundle: app) }
    }

    @Test func escapingSymlinkIsRejected() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("escape").path,
            withDestinationPath: "/tmp"
        )
        #expect(throws: (any Error).self) { try ArtifactInventory(directory: directory) }
    }

    @Test func dependencyClosureRejectsMissingLibraryAndAcceptsRelocatedLibrary() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("App.app")
        try Self.fixture(at: app)
        try Self.binary(dependency: "@rpath/libDependency.dylib", rpath: "@executable_path/../Frameworks")
            .write(to: app.appendingPathComponent("Contents/MacOS/App"))
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        #expect(throws: (any Error).self) { try MacBundleAudit.validate(bundle: app, target: target) }
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try Self.binary(type: 6).write(to: frameworks.appendingPathComponent("libDependency.dylib"))
        #expect(try MacBundleAudit.validate(bundle: app, target: target) == ["Contents/Frameworks/libDependency.dylib", ""])
    }

    @Test func existingAppRunForwardsArgumentsAndExitStatusWithoutBuilding() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("App.app")
        try Self.fixture(at: app)
        let before = try ArtifactInventory(directory: app)
        await #expect(throws: ExitCode(7)) {
            try await withDependencies {
                $0.macRunClient = MacRunClient(isMacOS: { true }, launch: { executable, arguments in
                    #expect(executable.lastPathComponent == "App")
                    #expect(arguments == ["--probe", "value with spaces"])
                    return 7
                })
            } operation: {
                try await DevRunCommand.parse(["--app", app.path, "--", "--probe", "value with spaces"]).run()
            }
        }
        try before.verify(directory: app)
    }

    @Test func frameworkHelpersPrecedeTheirContainingFrameworkInSigningOrder() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("App.app")
        try Self.fixture(at: app)
        let version = app.appendingPathComponent("Contents/Frameworks/Example.framework/Versions/A")
        try FileManager.default.createDirectory(at: version.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        try Self.binary(type: 6).write(to: version.appendingPathComponent("Example"))
        try Self.binary().write(to: version.appendingPathComponent("Helpers/Nested"))
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        #expect(try MacBundleAudit.validate(bundle: app, target: target) == [
            "Contents/Frameworks/Example.framework/Versions/A/Helpers/Nested",
            "Contents/Frameworks/Example.framework", "",
        ])
    }

    #if os(macOS)
    static func nativeFixture(at bundle: URL) throws {
        try fixture(at: bundle)
        let source = bundle.deletingLastPathComponent().appendingPathComponent("main.swift")
        try """
        import Foundation
        guard Array(CommandLine.arguments.dropFirst()) == ["first", "two words"] else { exit(2) }
        exit(7)
        """.write(to: source, atomically: true, encoding: .utf8)
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-target", "\(architecture)-apple-macosx15.0", source.path,
                              "-o", bundle.appendingPathComponent("Contents/MacOS/App").path]
        try compiler.run()
        compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)
        try FileManager.default.removeItem(at: source)
    }

    @Test func nativeAppRunForwardsArgumentsAndExitStatus() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("App.app")
        try Self.nativeFixture(at: app)
        let before = try ArtifactInventory(directory: app)
        await #expect(throws: ExitCode(7)) {
            try await withDependencies {
                $0.macRunClient = .liveValue
            } operation: {
                try await DevRunCommand.parse(["--app", app.path, "--", "first", "two words"]).run()
            }
        }
        try before.verify(directory: app)
    }
    #endif
}
