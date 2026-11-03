import XCLIUtils
import CustomDump
import Dependencies
import Foundation
import Testing
import XcodeProjects
import XPIF
import XUtils
@testable import XToolSupport

struct SwiftPMBuildDescriberTests {
    @Test(arguments: [nil, "org.example.widget"] as [String?])
    func generatesAppAndExtensionWithSchemaSettings(extensionBundleID: String?) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Assets"), withIntermediateDirectories: true)
        let absoluteResource = root.appending(path: "Shared.txt").path
        try Data().write(to: URL(filePath: absoluteResource))
        try writePlist(["UIDeviceFamily": [2], "CFBundleVersion": "42"], to: root.appending(path: "App.plist"))
        try writePlist(["NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"]],
                       to: root.appending(path: "Widget.plist"))
        let schema = try PackSchema(validating: .init(
            version: .v1,
            bundleID: "org.example.custom",
            product: "App",
            infoPath: "App.plist",
            entitlementsPath: "App.entitlements",
            iconPath: "Icon.png",
            resources: ["Assets", "Icon.png", absoluteResource],
            extensions: [
                .init(product: "Widget", bundleID: extensionBundleID, infoPath: "Widget.plist", resources: ["Assets"],
                      entitlementsPath: root.appending(path: "Widget.entitlements").path),
            ],
        ))
        let describer = describer(schema: schema, root: root)
        let result = try describer.writeXcodeProject(basePIF: pif(root: root, products: ["App", "Widget"]))
        #expect(result.bundleID == "org.example.custom")
        #expect(result.url == root.appending(path: "xtool/App.xcworkspace"))
        let workspace = try XcodeWorkspace(url: result.url)
        #expect(workspace.children == [
            .file(.init(base: .container, path: "..")),
            .file(.init(base: .group, path: ".xtool-tmp/App.xcodeproj")),
        ])
        let projectDir = root.appending(path: "xtool/.xtool-tmp")
        let project = try XcodeProject(url: projectDir.appending(path: "App.xcodeproj")).project
        let targets = project.targets.compactMap { target -> XCSchema.CommonTargetProperties? in
            guard case .native(let properties) = target else { return nil }
            return properties
        }
        #expect(targets.map(\.name) == ["App-App", "Widget-Extension"])
        let app = try #require(targets.first)
        let widget = try #require(targets.last)
        #expect(app.buildSettings["PRODUCT_BUNDLE_IDENTIFIER"] == .string("org.example.custom"))
        #expect(widget.buildSettings["PRODUCT_BUNDLE_IDENTIFIER"]
            == .string(extensionBundleID ?? "org.example.custom.Widget"))
        #expect(app.buildSettings["TARGETED_DEVICE_FAMILY[sdk=iphone*]"] == .string("2"))
        #expect(project.buildSettings["IPHONEOS_DEPLOYMENT_TARGET[config=Debug]"] == .string("16.0"))
        #expect(app.buildSettings["CODE_SIGN_ENTITLEMENTS"] == .string("../../App.entitlements"))
        #expect(widget.buildSettings["CODE_SIGN_ENTITLEMENTS"] == .string(root.appending(path: "Widget.entitlements").path))
        #expect(widget.buildSettings["APPLICATION_EXTENSION_API_ONLY"] == .string("YES"))
        #expect(app.dependencies == [.localTarget(.init(targetName: "Widget-Extension"), [])])
        #expect(app.packageProductTargetMembers.map { $0.packageProduct.productName } == ["App"])
        #expect(widget.packageProductTargetMembers.map { $0.packageProduct.productName } == ["Widget"])
        let appPlist = try readPlist(projectDir.appending(path: "App/Info.plist"))
        #expect(appPlist["CFBundleVersion"] as? String == "42")
        #expect(appPlist["CFBundleExecutable"] == nil)
        expectNoDifference(app.buildSettings["PRODUCT_NAME"], .string("App"))
        expectNoDifference(widget.buildSettings["PRODUCT_NAME"], .string("Widget"))
        expectNoDifference(app.product, .namePath(.init(components: [.child("Products"), .child("App.app")])))
        expectNoDifference(widget.product, .namePath(.init(components: [.child("Products"), .child("Widget.appex")])))
        #expect(appPlist["CFBundleIconFile"] as? String == "Icon")
        #expect(appPlist["UIDeviceFamily"] == nil)
        let widgetPlist = try readPlist(projectDir.appending(path: "Widget/Info.plist"))
        #expect((widgetPlist["NSExtension"] as? [String: String])?["NSExtensionPointIdentifier"]
            == "com.apple.widgetkit-extension")
        let projectText = try String(contentsOf: projectDir.appending(path: "App.xcodeproj/project.pbxproj"), encoding: .utf8)
        #expect(projectText.contains("Embed App Extensions"))
        #expect(projectText.contains("Copy Root Resources"))
        #expect(projectText.contains("../../Assets"))
        #expect(projectText.contains(absoluteResource))
        // The icon is also listed as a resource; the copy phase should contain it only once.
        let appGroup = try #require(project.topLevelReferences.first)
        guard case .group(let group) = appGroup else {
            Issue.record("Expected the app's group")
            return
        }
        #expect(group.children.count == 5)
    }

    @Test func dumpsPIFAndGeneratesProjectForSwiftPackage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("""
        // swift-tools-version:6.0
        import PackageDescription
        let package = Package(
            name: "Sample", platforms: [.iOS(.v15)],
            products: [.library(name: "Sample", targets: ["Sample"]),
                       .library(name: "DynamicHelper", type: .dynamic, targets: ["Sample"]),
                       .executable(name: "Tool", targets: ["Tool"])],
            targets: [.target(name: "Sample"), .executableTarget(name: "Tool")]
        )
        """.utf8).write(to: root.appending(path: "Package.swift"))
        try FileManager.default.createDirectory(at: root.appending(path: "Sources/Sample"), withIntermediateDirectories: true)
        try Data("public struct Sample {}".utf8).write(to: root.appending(path: "Sources/Sample/Sample.swift"))
        try FileManager.default.createDirectory(at: root.appending(path: "Sources/Tool"), withIntermediateDirectories: true)
        try Data("print(42)".utf8).write(to: root.appending(path: "Sources/Tool/main.swift"))
        let result = try await withDependencies {
            $0.out = .liveValue
        } operation: {
            let describer = describer(schema: .default, root: root)
            let description = try await describer.describe()
            let app = try #require(description.workspace.projects.flatMap(\.targets).first { $0.id == "xtool:main-app" })
            expectNoDifference(app.common.name, "Sample-App")
            return try await describer.writeXcodeProject()
        }
        #expect(result.bundleID == "com.example.Sample")
        let project = try XcodeProject(url: root.appending(path: "xtool/.xtool-tmp/Sample.xcodeproj"))
        #expect(project.project.targets.count == 1)
        let plist = try readPlist(root.appending(path: "xtool/.xtool-tmp/Sample/Info.plist"))
        #expect(plist["MinimumOSVersion"] == nil)
        #expect(plist["UILaunchScreen"] == nil)
        #expect(project.project.buildSettings["IPHONEOS_DEPLOYMENT_TARGET"] == .string("15.0"))
    }

    @Test(arguments: [nil, "App"] as [String?])
    func selectsPrimaryProductAndPreservesDynamicVariant(expected: String?) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = try PackSchema(validating: .init(version: .v1, orgID: "com.example", product: expected))
        let describer = describer(schema: schema, root: root)
        var pif = pif(root: root, products: [])
        var product = XPIF.Target(id: "PACKAGE-PRODUCT:App", productType: .packageProduct,
                                  name: "App-product", productName: "App")
        let variant = XPIF.Target(id: "PACKAGE-PRODUCT:Variant", productType: .framework,
                                  name: "App-product", productName: "AppDynamic")
        product.dynamicTargetVariantId = variant.id
        // Put the variant first so explicit product selection cannot accidentally pick it.
        pif.workspace.projects[0].targets = [.target(variant), .target(product)]
        let description = try describer.describe(basePIF: pif)
        let targets = description.workspace.projects[0].targets
        expectNoDifference(Array(targets.prefix(2)), pif.workspace.projects[0].targets)
        let app = try #require(targets.first { $0.id == "xtool:main-app" })
        expectNoDifference(app.common.dependencies.map(\.targetId), [product.id])
        let result = try describer.writeXcodeProject(basePIF: pif)
        expectNoDifference(result.bundleID, "com.example.App")
        let project = try XcodeProject(url: root.appending(path: "xtool/.xtool-tmp/App.xcodeproj"))
        expectNoDifference(project.project.targets.map(\.name), ["App-App"])

        // Separately declared dynamic libraries remain in the graph as dependencies, but
        // must not make app selection ambiguous or be selectable as apps themselves.
        let other = XPIF.Target(id: "PACKAGE-PRODUCT:Other", productType: .framework,
                                name: "Other-product", productName: "Other")
        let dylib = XPIF.Target(id: "PACKAGE-PRODUCT:Dylib", productType: .dynamicLibrary,
                                name: "Dylib-product", productName: "Dylib")
        pif.workspace.projects[0].targets.append(contentsOf: [.target(other), .target(dylib)])
        let automatic = self.describer(schema: .default, root: root)
        let descriptionWithDependencies = try automatic.describe(basePIF: pif)
        expectNoDifference(Array(descriptionWithDependencies.workspace.projects[0].targets.prefix(4)),
                           pif.workspace.projects[0].targets)
        expectNoDifference(try automatic.writeXcodeProject(basePIF: pif).bundleID, "com.example.App")
        for name in ["Other", "Dylib"] {
            let schema = try PackSchema(validating: .init(version: .v1, orgID: "com.example", product: name))
            let explicit = self.describer(schema: schema, root: root)
            #expect(throws: Console.Error.self) { try explicit.describe(basePIF: pif) }
            #expect(throws: Console.Error.self) { try explicit.writeXcodeProject(basePIF: pif) }
        }
        pif.workspace.projects[0].targets = [.target(other), .target(dylib)]
        #expect(throws: Console.Error.self) { try automatic.describe(basePIF: pif) }
        #expect(throws: Console.Error.self) { try automatic.writeXcodeProject(basePIF: pif) }
    }

    @Test(arguments: [0, 2])
    func rejectsMissingOrAmbiguousProducts(count: Int) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let describer = describer(schema: .default, root: root)
        let pif = pif(root: root, products: (0..<count).map { "Product\($0)" })
        #expect(throws: Console.Error.self) { try describer.writeXcodeProject(basePIF: pif) }
        #expect(throws: Console.Error.self) { try describer.describe(basePIF: pif) }
    }

    @Test func rejectsUnknownExtensionProduct() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = try PackSchema(validating: .init(
            version: .v1, orgID: "com.example", product: "App",
            extensions: [.init(product: "Missing", infoPath: "Widget.plist")]
        ))
        let describer = describer(schema: schema, root: root)
        #expect(throws: Console.Error.self) {
            try describer.writeXcodeProject(basePIF: pif(root: root, products: ["App"]))
        }
        #expect(throws: Console.Error.self) {
            try describer.describe(basePIF: pif(root: root, products: ["App"]))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "xtool").path))
    }

    @Test(arguments: [nil, "App", "Tool"] as [String?])
    func selectsLibrariesAlongsideExecutables(expected: String?) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = try PackSchema(validating: .init(version: .v1, orgID: "com.example", product: expected))
        let describer = describer(schema: schema, root: root)
        var pif = pif(root: root, products: ["App"])
        pif.workspace.projects[0].targets.append(.target(.init(
            id: "PACKAGE-PRODUCT:Tool", productType: .executable, name: "Tool-product", productName: "Tool"
        )))
        if expected == "Tool" {
            #expect(throws: Console.Error.self) { try describer.describe(basePIF: pif) }
            #expect(throws: Console.Error.self) { try describer.writeXcodeProject(basePIF: pif) }
        } else {
            let description = try describer.describe(basePIF: pif)
            let app = try #require(description.workspace.projects[0].targets.first { $0.id == "xtool:main-app" })
            expectNoDifference(app.common.name, "App-App")
            expectNoDifference(try describer.writeXcodeProject(basePIF: pif).bundleID, "com.example.App")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func describer(schema: PackSchema, root: URL) -> SwiftPMBuildDescriber {
        SwiftPMBuildDescriber(project: .init(
            base: .init(rootDirectory: root, schema: schema),
            manifest: root.appending(path: "Package.swift")
        ))
    }

    private func pif(root: URL, products: [String]) -> XPIF.Container {
        var settings = XPIF.BuildSettings()
        settings[.IPHONEOS_DEPLOYMENT_TARGET] = "16.0"
        let project = XPIF.Project(
            id: "package", path: root.appending(path: "Package.swift").path, projectDir: root.path, name: "Package",
            buildConfigs: [.init(id: "debug", name: "Debug", settings: settings)],
            targets: products.map { name in
                .target(.init(id: .init("PACKAGE-PRODUCT:\(name)"), productType: .packageProduct,
                              name: "\(name)-product", productName: name))
            }
        )
        return XPIF.Container(workspace: .init(id: "workspace", name: "Package", path: root.path, projects: [project]))
    }

    private func writePlist(_ plist: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    private func readPlist(_ url: URL) throws -> [String: Any] {
        try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }
}
