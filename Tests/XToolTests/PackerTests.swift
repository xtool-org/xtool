import Testing
import Foundation
@testable import PackLib

@Test(arguments: [ApplePlatform.macOS, .macCatalyst], [false, true])
func nativeDesktopPackageResourcesRequireSwiftBuild(platform: ApplePlatform, extensionOnly: Bool) throws {
    var app = Plan.Product(
        type: .application, product: "Example", deploymentTarget: "17.0", bundleID: "com.example.app",
        infoPlist: [:], resources: [.root(source: "custom.txt")], iconPath: nil, entitlementsPath: nil
    )
    var ext = app
    ext.type = .appExtension
    ext.product = "Extension"
    let resource = Plan.Resource.bundle(package: "Example", target: "Content")
    if extensionOnly {
        ext.resources.append(resource)
    } else {
        app.resources.append(resource)
    }
    let plan = Plan(app: app, extensions: [ext])
    #expect(throws: StringError.self) {
        try plan.validateResourceBundleSupport(platform: platform, buildSystem: .swiftPM)
    }
    try plan.validateResourceBundleSupport(platform: platform, buildSystem: .swiftBuild)
    try plan.validateResourceBundleSupport(platform: .iOS, buildSystem: .swiftPM)
    try plan.validateResourceBundleSupport(platform: .tvOS, buildSystem: .swiftPM)

    app.resources = [.root(source: "custom.txt")]
    ext.resources = []
    try Plan(app: app, extensions: [ext]).validateResourceBundleSupport(platform: platform, buildSystem: .swiftPM)
}

@Test func cfBundleSupportedPlatformsFollowsBuildTriple() {
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios") == ["iPhoneOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios-simulator") == ["iPhoneSimulator"])

    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0") == ["iPhoneOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0-simulator") == ["iPhoneSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-ios-simulator") == ["iPhoneSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-macosx") == ["MacOSX"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-macosx") == ["MacOSX"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0-macabi") == ["MacOSX"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-ios-macabi") == ["MacOSX"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-tvos") == ["AppleTVOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-tvos17.0-simulator") == ["AppleTVSimulator"])

    #expect(Packer.cfBundleSupportedPlatforms(for: "unknown-triple") == ["iPhoneOS"])
}

@Test(arguments: ["arm64-apple-tvos", "arm64-apple-ios-macabi"])
func packsPlatformBundleAndExtension(triple: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PackerTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let binDir = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    let settings = try await BuildSettings(configuration: .release, triple: triple, buildSystem: .swiftPM)
    let platform = settings.platform
    let app = Plan.Product(
        type: .application, product: "Example", deploymentTarget: "17.0", bundleID: "com.example.app",
        infoPlist: ["CFBundleIdentifier": "com.example.app", "DTSDKBuild": "stale-build"],
        resources: [.bundle(package: "Example", target: "Content"), .library(name: "Shared")],
        iconPath: nil, entitlementsPath: nil
    )
    var ext = app
    ext.type = .appExtension
    ext.product = "Extension"
    ext.resources = []
    let executable = Data([0, 1, 2, 3])
    for product in [app, ext] {
        try executable.write(to: binDir.appendingPathComponent(product.targetName))
    }
    let resources = binDir.appendingPathComponent("Example_Content.bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
    try Data("resource".utf8).write(to: resources.appendingPathComponent("content.txt"))
    try executable.write(to: binDir.appendingPathComponent("libShared.dylib"))

    let output = root.appendingPathComponent("Example.app", isDirectory: true)
    try await Packer(buildSettings: settings, plan: Plan(app: app, extensions: [ext]))
        .packProducts(binDir: binDir, outputURL: output, buildMetadata: ["DTSDKBuild": "recorded-sdk-build"])

    let prefix = platform.usesContentsDirectory ? "Contents/" : ""
    let executablePrefix = platform.usesContentsDirectory ? "Contents/MacOS/" : ""
    let resourcePrefix = platform.usesContentsDirectory ? "Contents/Resources/" : ""
    #expect(try Data(contentsOf: output.appendingPathComponent("\(executablePrefix)Example")) == executable)
    #expect(try Data(contentsOf: output.appendingPathComponent("\(resourcePrefix)Example_Content.bundle/content.txt"))
        == Data("resource".utf8))
    #expect(try Data(contentsOf: output.appendingPathComponent("\(prefix)Frameworks/libShared.dylib")) == executable)
    #expect(try Data(contentsOf: output.appendingPathComponent("\(prefix)PlugIns/Extension.appex/\(executablePrefix)Extension"))
        == executable)

    let plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: output.appendingPathComponent("\(prefix)Info.plist")), format: nil
    ) as? [String: Any]
    #expect(plist?["CFBundleSupportedPlatforms"] as? [String] == [platform.supportedPlatform(triple: triple)])
    #expect(plist?["DTSDKBuild"] as? String == "recorded-sdk-build")
    let extensionInfo = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: output.appendingPathComponent("\(prefix)PlugIns/Extension.appex/\(prefix)Info.plist")), format: nil
    ) as? [String: Any]
    #expect(extensionInfo?["DTSDKBuild"] as? String == "recorded-sdk-build")
    if platform.usesContentsDirectory {
        #expect(plist?["LSRequiresIPhoneOS"] == nil)
        #expect(plist?["UIRequiredDeviceCapabilities"] == nil)
    }
}
