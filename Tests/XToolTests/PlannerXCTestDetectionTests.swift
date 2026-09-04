import Testing
import Foundation
import PackLib

/// Builds a real, minimal SwiftPM package fixture (no external dependencies, so this runs
/// offline) and exercises `Planner.createPlan()` against it for real via `swift package
/// describe`/`show-dependencies` subprocesses. Verifies the SwiftPM test-target detection added
/// for xtool test support; doesn't (and can't, without a Darwin SDK configured) exercise the
/// actual `--build-tests`/packaging step `Packer` performs once a plan says a test target exists.
@Test func testPlannerDetectsSwiftPMTestTargets() async throws {
    let fixture = try makeFixturePackage(name: "PlannerFixtureWithTests", includeTestTarget: true)
    defer { try? FileManager.default.removeItem(at: fixture) }

    let buildSettings = try await BuildSettings(
        configuration: .debug,
        triple: "arm64-apple-ios",
        packagePath: fixture.path
    )
    let planner = Planner(buildSettings: buildSettings, schema: .default)
    let plan = try await planner.createPlan()

    let xcTest = try #require(plan.xcTest)
    #expect(xcTest.packageName == "PlannerFixtureWithTests")
    #expect(xcTest.testProductName == "PlannerFixtureWithTestsPackageTests")
    #expect(xcTest.runnerProduct == "PlannerFixtureWithTestsXCTRunner")
    // Deliberately not derived from the app's own bundle ID -- see the doc comment on
    // `Planner.xcTestPlan(from:app:)`'s `bundleID` argument.
    #expect(xcTest.bundleID == "xtool.xctrunner")
    #expect(xcTest.testTargetNames == ["PlannerFixtureWithTestsTests"])
}

@Test func testPlannerSkipsXCTestPlanWhenNoTestTargetsExist() async throws {
    let fixture = try makeFixturePackage(name: "PlannerFixtureWithoutTests", includeTestTarget: false)
    defer { try? FileManager.default.removeItem(at: fixture) }

    let buildSettings = try await BuildSettings(
        configuration: .debug,
        triple: "arm64-apple-ios",
        packagePath: fixture.path
    )
    let planner = Planner(buildSettings: buildSettings, schema: .default)
    let plan = try await planner.createPlan()

    #expect(plan.xcTest == nil)
}

private func makeFixturePackage(name: String, includeTestTarget: Bool) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    let sources = root.appendingPathComponent("Sources/\(name)")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try Data("public func hello() -> String { \"hello\" }\n".utf8)
        .write(to: sources.appendingPathComponent("\(name).swift"))

    let testTargetDecl: String
    if includeTestTarget {
        let tests = root.appendingPathComponent("Tests/\(name)Tests")
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try Data("import XCTest\nfinal class SmokeTests: XCTestCase { func testHello() {} }\n".utf8)
            .write(to: tests.appendingPathComponent("SmokeTests.swift"))
        testTargetDecl = """
        ,
                .testTarget(name: "\(name)Tests", dependencies: ["\(name)"])
        """
    } else {
        testTargetDecl = ""
    }

    let packageSwift = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "\(name)",
        platforms: [.iOS(.v16)],
        products: [.library(name: "\(name)", targets: ["\(name)"])],
        targets: [
            .target(name: "\(name)")\(testTargetDecl)
        ]
    )
    """
    try Data(packageSwift.utf8).write(to: root.appendingPathComponent("Package.swift"))

    return root
}
