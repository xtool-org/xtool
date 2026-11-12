import Testing
import Foundation
@testable import PackLib

@Test func cfBundleSupportedPlatformsFollowsBuildTriple() {
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios") == ["iPhoneOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios-simulator") == ["iPhoneSimulator"])

    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0") == ["iPhoneOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0-simulator") == ["iPhoneSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-ios-simulator") == ["iPhoneSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-macosx") == ["MacOSX"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-macosx") == ["MacOSX"])

    #expect(Packer.cfBundleSupportedPlatforms(for: "unknown-triple") == ["iPhoneOS"])
}

// https://github.com/xtool-org/xtool/issues/433
@Test func packSkipsBundlesSwiftPMDidNotBuild() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let binDir = root.appendingPathComponent("bin", isDirectory: true)
    let outputURL = root.appendingPathComponent("App.app", isDirectory: true)
    try fm.createDirectory(at: binDir.appendingPathComponent("pkg_Built.bundle"), withIntermediateDirectories: true)
    try Data().write(to: binDir.appendingPathComponent("App-App"))

    let product = Plan.Product(
        type: .application,
        product: "App",
        deploymentTarget: "17.0",
        bundleID: "com.example.App",
        infoPlist: [:],
        resources: [
            .bundle(package: "pkg", target: "Built"),
            .bundle(package: "pkg", target: "NotBuilt"),
        ]
    )
    let settings = try await BuildSettings(configuration: .debug, triple: "arm64-apple-ios", buildSystem: .swiftPM)
    let packer = Packer(buildSettings: settings, plan: Plan(app: product, extensions: []))
    try await withThrowingTaskGroup(of: Void.self) { group in
        try packer.pack(product: product, binDir: binDir, outputURL: outputURL, &group)
        try await group.waitForAll()
    }

    #expect(fm.fileExists(atPath: outputURL.appendingPathComponent("pkg_Built.bundle").path))
    #expect(!fm.fileExists(atPath: outputURL.appendingPathComponent("pkg_NotBuilt.bundle").path))
}
