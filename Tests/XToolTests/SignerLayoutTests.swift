import Foundation
import Testing
@testable import XKit

/// How the signer copes with executables that have little room for a signature.
@Suite struct SignerLayoutTests {
    private func sign(machO: Data) async throws -> (executable: URL, error: (any Error)?) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = try FakeApp.writeBundle(
            at: root.appendingPathComponent("Test.app"), id: "com.example.layout", machO: machO
        )
        let ents = try PropertyListDecoder().decode(
            Entitlements.self,
            from: PropertyListSerialization.data(fromPropertyList: ["get-task-allow": false], format: .xml, options: 0)
        )
        do {
            try await Signer.first().sign(
                app: app, identity: .adhoc, entitlementMapping: [app: ents], progress: { _ in }
            )
            return (app.appendingPathComponent("main"), nil)
        } catch {
            return (app.appendingPathComponent("main"), error)
        }
    }

    @Test func failureLeavesTheExecutableUntouched() async throws {
        // the first section starts right after the load commands: no room for LC_CODE_SIGNATURE
        let cramped = FakeApp.machO(contentOffset: 32 + 72 + 152 + 72 + 24)
        let result = try await sign(machO: cramped)
        defer { try? FileManager.default.removeItem(at: result.executable.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(result.error != nil)
        #expect(try Data(contentsOf: result.executable) == cramped)
    }

    @Test func freeSpaceIsMeasuredFromTheFirstSectionWhateverItsName() async throws {
        let result = try await sign(machO: FakeApp.machO(sectionName: "__const"))
        defer { try? FileManager.default.removeItem(at: result.executable.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(result.error == nil)
        #expect(try FakeApp.entitlements(ofExecutable: result.executable)?["get-task-allow"] as? Bool == false)
    }
}
