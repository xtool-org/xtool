import Foundation
import Testing
@testable import PackLib

private let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
private let fixtureCatalog = fixtures.appendingPathComponent("Test.xcassets")

private func product(
    type: Plan.ProductType = .application,
    catalog: URL? = fixtureCatalog,
    iconPath: String? = nil
) -> Plan.Product {
    Plan.Product(
        type: type,
        product: "Demo",
        deploymentTarget: "17.0",
        bundleID: "com.example.Demo",
        infoPlist: [:],
        resources: [],
        iconPath: iconPath,
        entitlementsPath: nil,
        assetCatalogPath: catalog?.path
    )
}

@Test func compileAssetsProducesCarAndIconPlist() async throws {
    let assets = try #require(try await Packer.compileAssets(for: product()))

    // Assets.car is a BOM store, and the facet names are stored in clear.
    #expect(assets.carData.prefix(8) == Data("BOMStore".utf8))
    for name in ["AppIcon", "Logo", "Brand"] {
        #expect(assets.carData.contains(Data(name.utf8)), "missing facet \(name)")
    }

    #expect(assets.hasAppIcon)
    #expect(assets.infoPlistAdditions["CFBundleIconName"] as? String == "AppIcon")
    let icons = try #require(assets.infoPlistAdditions["CFBundleIcons"] as? [String: any Sendable])
    #expect(icons["CFBundleIconName"] as? String == "AppIcon")
}

// Xcode 14+ defaults to a single 1024x1024 "universal" icon with no scale. AssetKit does not handle
// that format yet, so this is expected to fail until it does; `withKnownIssue` will flag when it starts to pass.
@Test func compileAssetsSingleSizeAppIcon() async throws {
    let catalog = fixtures.appendingPathComponent("SingleSize.xcassets")
    await withKnownIssue("AssetKit rejects single-size universal app icons") {
        let assets = try #require(try await Packer.compileAssets(for: product(catalog: catalog)))
        #expect(assets.hasAppIcon)
    }
}

@Test func catalogAppIconOverridesIconPath() async throws {
    let withIcon = product(iconPath: "Icon.png")
    let assets = try await Packer.compileAssets(for: withIcon)
    #expect(Packer.iconPath(for: withIcon, assets: assets) == nil)
    #expect(Packer.iconPath(for: withIcon, assets: nil) == "Icon.png")
}

@Test func compiledAssetsAreWrittenIntoTheBundle() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xtool-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let assets = try #require(try await Packer.compileAssets(for: product()))
    try assets.write(into: dir)
    #expect(try Data(contentsOf: dir.appendingPathComponent("Assets.car")) == assets.carData)
    #expect(!assets.looseFiles.isEmpty)
    for file in assets.looseFiles {
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(file.name).path))
    }
}

@Test func compileAssetsIsNilWithoutCatalog() async throws {
    #expect(try await Packer.compileAssets(for: product(catalog: nil)) == nil)
}

@Test func compileAssetsFailsOnMissingCatalog() async {
    let missing = fixtureCatalog.deletingLastPathComponent().appendingPathComponent("Missing.xcassets")
    await #expect(throws: (any Error).self) {
        _ = try await Packer.compileAssets(for: product(catalog: missing))
    }
}

@Test func compiledCatalogIsDeterministic() async throws {
    let first = try #require(try await Packer.compileAssets(for: product()))
    let second = try #require(try await Packer.compileAssets(for: product()))
    #expect(first.carData == second.carData)
}

@Test func schemaAcceptsAssetCatalogsOnAppAndExtensions() async throws {
    let yaml = """
    version: 1
    orgID: com.example
    assetCatalogs: [Assets.xcassets]
    extensions:
      - product: Widget
        infoPath: Widget.plist
        assetCatalogs: [Widget/Assets.xcassets]
    """
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("xtool-\(UUID().uuidString).yml")
    try Data(yaml.utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let schema = try await PackSchema(url: file)
    #expect(schema.assetCatalogs == ["Assets.xcassets"])
    #expect(schema.extensions?.first?.assetCatalogs == ["Widget/Assets.xcassets"])
}

@Test func schemaRejectsMultipleCatalogsPerProduct() throws {
    let app = PackSchemaBase(version: .v1, orgID: "com.example", assetCatalogs: ["A.xcassets", "B.xcassets"])
    #expect(throws: (any Error).self) { try PackSchema(validating: app) }

    let ext = PackSchemaBase.Extension(
        product: "Widget",
        infoPath: "Widget.plist",
        assetCatalogs: ["A.xcassets", "B.xcassets"]
    )
    let withExt = PackSchemaBase(version: .v1, orgID: "com.example", extensions: [ext])
    #expect(throws: (any Error).self) { try PackSchema(validating: withExt) }
}

@Test func xcodePackerFindsAppIconName() {
    #expect(XcodePacker.appIconName(inCatalogAt: fixtureCatalog) == "AppIcon")
    #expect(XcodePacker.appIconName(inCatalogAt: fixtureCatalog.appendingPathComponent("Logo.imageset")) == nil)
}

@Test func xcodePackerPassesCatalogThroughUncompiled() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xtool-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let app = product(catalog: URL(fileURLWithPath: "Assets.xcassets"))
    let plan = Plan(app: app, extensions: [])
    let workspace = try await XcodePacker(plan: plan).createProject(at: root)
    #expect(workspace.pathExtension == "xcworkspace")

    let pbxproj = try String(
        contentsOf: root.appendingPathComponent("xtool/.xtool-tmp/Demo.xcodeproj/project.pbxproj"),
        encoding: .utf8
    )
    #expect(pbxproj.contains("folder.assetcatalog"))
    #expect(pbxproj.contains("Assets.xcassets"))
    #expect(pbxproj.contains("PBXResourcesBuildPhase"))
}
