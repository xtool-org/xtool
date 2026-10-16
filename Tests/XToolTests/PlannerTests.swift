import Foundation
import Testing
@testable import PackLib

@Test(arguments: ["arm64-apple-ios", "arm64-apple-tvos", "arm64-apple-ios-macabi"], [nil, "13.0", "19.0"] as [String?])
func plannerUsesTargetDeploymentAndDeviceFamily(triple: String, customMinimum: String?) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlannerTests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sources = root.appendingPathComponent("Sources/Example", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try Data("public enum Example {}\n".utf8).write(to: sources.appendingPathComponent("Example.swift"))
    try Data("""
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "Example",
        platforms: [.iOS("17.0"), .tvOS("18.0"), .macCatalyst("17.0"), .macOS("14.0")],
        products: [.library(name: "Example", targets: ["Example"])],
        targets: [.target(name: "Example")]
    )
    """.utf8).write(to: root.appendingPathComponent("Package.swift"))
    var settings = try await BuildSettings(
        configuration: .release, triple: triple, buildSystem: .swiftPM, packagePath: root.path
    )
    // Describing a package does not compile it or require a cross-compilation SDK.
    settings.sdkOptions = []
    var schema = PackSchema.default
    if let customMinimum {
        let infoPath = root.appendingPathComponent("Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["MinimumOSVersion": customMinimum], format: .xml, options: 0)
            .write(to: infoPath)
        var base = schema.base
        base.infoPath = infoPath.path
        schema = try PackSchema(validating: base)
    }
    let plan = try await Planner(buildSettings: settings, schema: schema).createPlan()
    switch settings.platform {
    case .iOS:
        #expect(plan.app.deploymentTarget == "17.0")
        #expect(plan.app.infoPlist["MinimumOSVersion"] as? String == (customMinimum == "19.0" ? "19.0" : "17.0"))
        #expect(plan.app.infoPlist["UIDeviceFamily"] as? [Int] == [1, 2])
    case .tvOS:
        #expect(plan.app.deploymentTarget == "18.0")
        #expect(plan.app.infoPlist["MinimumOSVersion"] as? String == (customMinimum == "19.0" ? "19.0" : "18.0"))
        #expect(plan.app.infoPlist["UIDeviceFamily"] as? [Int] == [3])
        #expect(plan.app.infoPlist["UISupportedInterfaceOrientations"] == nil)
    case .macCatalyst:
        #expect(plan.app.deploymentTarget == "17.0")
        #expect(plan.app.infoPlist["LSMinimumSystemVersion"] as? String == "14.0")
        #expect(plan.app.infoPlist["MinimumOSVersion"] as? String == customMinimum)
        #expect(plan.app.infoPlist["UIDeviceFamily"] as? [Int] == [6])
    case .macOS:
        Issue.record("Unexpected test platform")
    }
}
