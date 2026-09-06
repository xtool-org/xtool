import Testing
import Foundation
@testable import XToolSupport

/// Covers `TestCommand.xcTestCaseClassNames`'s regex/closure-based `XCTestCase` discovery --
/// added after a real-hardware run of `--test-target` against a real-world package (not a crafted
/// fixture) returned 0 tests despite the target having many concrete UI test classes. Root cause:
/// every one of those classes inherited from a shared, project-local base class (itself with no
/// test methods of its own) rather than `XCTestCase` directly, which the original
/// direct-subclass-only regex missed entirely.
@Test func testDiscoversDirectXCTestCaseSubclass() throws {
    let dir = try makeSwiftFilesFixture([
        "Direct.swift": """
        import XCTest
        final class DirectTests: XCTestCase {
            func testSomething() {}
        }
        """,
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(TestCommand.xcTestCaseClassNames(inDirectory: dir) == ["DirectTests"])
}

@Test func testDiscoversIndirectXCTestCaseSubclassThroughSharedBase() throws {
    let dir = try makeSwiftFilesFixture([
        "Base.swift": """
        import XCTest
        class BaseUITestCase: XCTestCase {
            func helper() {}
        }
        """,
        "Concrete.swift": """
        final class LoginUITests: BaseUITestCase {
            func testLoginScreenAppears() {}
        }
        final class SettingsUITests: BaseUITestCase {
            func testSettingsScreenAppears() {}
        }
        """,
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(
        TestCommand.xcTestCaseClassNames(inDirectory: dir).sorted()
            == ["LoginUITests", "SettingsUITests"]
    )
}

@Test func testExcludesAbstractBaseWithNoOwnTestMethods() throws {
    let dir = try makeSwiftFilesFixture([
        "Base.swift": """
        import XCTest
        class BaseUITestCase: XCTestCase {
            func notATestMethod() {}
        }
        """,
        "Concrete.swift": """
        final class ConcreteUITests: BaseUITestCase {
            func testReal() {}
        }
        """,
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    // `BaseUITestCase` must not appear -- filtering on it alone would match zero actual tests,
    // reproducing the exact bug this whole test file exists to guard against.
    #expect(TestCommand.xcTestCaseClassNames(inDirectory: dir) == ["ConcreteUITests"])
}

@Test func testExcludesUnrelatedClasses() throws {
    let dir = try makeSwiftFilesFixture([
        "Model.swift": """
        final class SomeModel {
            func testIsNotATestMethodContextButMatchesPrefix() {}
        }
        """,
        "Real.swift": """
        import XCTest
        final class RealTests: XCTestCase {
            func testReal() {}
        }
        """,
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(TestCommand.xcTestCaseClassNames(inDirectory: dir) == ["RealTests"])
}

/// `details` message shape observed from a device's `InstallationProxyClient.StatusError` when a
/// free Apple Developer account's 3-app install cap is hit.
@Test func testInstallCapacityMessageParsesInstalledBundleIDsAndSuggestsUninstall() throws {
    let details = """
    This device has reached the maximum number of installed apps using a free developer profile: {(
        "ABCDE12345.XTL-ABCDE12345.com.example.MyApp.xctrunner",
        "ABCDE12345.XTL-ABCDE12345.com.example.OtherApp",
        "ABCDE12345.XTL-ABCDE12345.com.example.MyApp"
    )}
    """

    let message = try #require(TestCommand.installCapacityMessage(fromDetails: details))
    #expect(message.contains("XTL-ABCDE12345.com.example.MyApp.xctrunner"))
    #expect(message.contains("xtool uninstall XTL-ABCDE12345.com.example.MyApp.xctrunner"))
}

@Test func testInstallCapacityMessageReturnsNilForUnrelatedDetails() {
    #expect(TestCommand.installCapacityMessage(fromDetails: "Some other install failure entirely") == nil)
}

private func makeSwiftFilesFixture(_ files: [String: String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("xctest-discovery-fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, contents) in files {
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    return dir
}
