import CustomDump
import Foundation
import Testing
import XCLIUtils
import XPIF
@testable import XToolSupport

struct DirectBuildDescriptionTests {
    @Test(arguments: [nil, "org.example.widget"] as [String?])
    func packagesSchemaContents(extensionBundleID: String?) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Assets"), withIntermediateDirectories: true)
        let shared = root.appending(path: "Shared.txt")
        try Data().write(to: shared)
        try writePlist([
            "CFBundleVersion": "42", "CFBundleShortVersionString": "2.3",
            "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleExecutable": "${EXECUTABLE_NAME}",
            "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)",
            "CFBundleName": "Custom name",
            "CFBundleDisplayName": "My App", "NSCameraUsageDescription": "Take a photo",
            "UIDeviceFamily": [2], "UISupportedInterfaceOrientations": ["UIInterfaceOrientationLandscapeLeft"],
        ], to: root.appending(path: "App.plist"))
        try writePlist(["NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"]],
                       to: root.appending(path: "Widget.plist"))
        let schema = try PackSchema(validating: .init(
            version: .v1, bundleID: "org.example.app", product: "App", infoPath: "App.plist",
            iconPath: "Icon.png", resources: ["Assets", "Icon.png", shared.path],
            extensions: [.init(product: "Widget", bundleID: extensionBundleID, infoPath: "Widget.plist",
                               resources: ["Assets", shared.path])]
        ))
        let description = try describe(schema: schema, root: root, products: ["App", "Widget"])
        let project = try #require(description.workspace.projects.first)
        let app = try #require(project.targets.first { $0.id == "xtool:main-app" })
        let widget = try #require(project.targets.first { $0.id == "xtool:extension:Widget" })
        if case .target(let target) = widget {
            expectNoDifference(target.productName, "Widget.appex")
            expectNoDifference(target.productType, .appExtension)
        } else {
            Issue.record("Expected a native extension target")
        }
        expectNoDifference(app.common.dependencies.map(\.targetId), ["PACKAGE-PRODUCT:App", widget.id])
        expectNoDifference(widget.common.dependencies.map(\.targetId), ["PACKAGE-PRODUCT:Widget"])
        let appSettings = try #require(app.common.buildConfigs.first?.settings)
        let widgetSettings = try #require(widget.common.buildConfigs.first?.settings)
        expectNoDifference(appSettings[single: "TARGETED_DEVICE_FAMILY[sdk=iphone*]"], "2")
        expectNoDifference(widgetSettings[.PRODUCT_BUNDLE_IDENTIFIER], extensionBundleID ?? "org.example.app.Widget")
        expectNoDifference(widgetSettings[.APPLICATION_EXTENSION_API_ONLY], "YES")
        expectNoDifference(widgetSettings[.SKIP_INSTALL], "YES")
        expectNoDifference(widgetSettings[.PRODUCT_NAME], "Widget")
        expectNoDifference(appSettings[.GENERATE_INFOPLIST_FILE], "YES")
        expectNoDifference(appSettings[.CURRENT_PROJECT_VERSION], "42")
        expectNoDifference(appSettings[.MARKETING_VERSION], "2.3")
        expectNoDifference(appSettings[.PRODUCT_BUNDLE_IDENTIFIER], "org.example.app")
        expectNoDifference(appSettings[single: "EXECUTABLE_NAME"], "App")
        expectNoDifference(appSettings[single: "DEVELOPMENT_LANGUAGE"], "en")
        #expect(appSettings[multiple: "INFOPLIST_KEY_UISupportedInterfaceOrientations[sdk=iphone*]"] == nil)
        let embed = try #require(copyPhases(app).first { $0.destinationSubfolder == .plugins })
        expectNoDifference(embed.files.map(\.ref), [.targetProduct(id: widget.id)])
        let appResources = try #require(copyPhases(app).first { $0.destinationSubfolder == .resources })
        let widgetResources = try #require(copyPhases(widget).first { $0.destinationSubfolder == .resources })
        let references = project.mainGroup.subitems.compactMap { reference -> XPIF.FileReference? in
            guard case .file(let file) = reference else { return nil }
            return file
        }
        func paths(_ phase: XPIF.CopyFilesBuildPhase) -> [String] {
            phase.files.compactMap { file in
                guard case .reference(let id) = file.ref else { return nil }
                return references.first { $0.id == id }?.path
            }
        }
        expectNoDifference(paths(appResources), [root.appending(path: "Assets").path,
                                                root.appending(path: "Icon.png").path, shared.path])
        expectNoDifference(paths(widgetResources), [root.appending(path: "Assets").path, shared.path])
        expectNoDifference(references.first { $0.path == root.appending(path: "Assets").path }?.fileType, "folder")
        let appPlist = try readPlist(appSettings)
        expectNoDifference(appPlist["CFBundleVersion"] as? String, "42")
        expectNoDifference(appPlist["CFBundleShortVersionString"] as? String, "2.3")
        expectNoDifference(appPlist["CFBundleDisplayName"] as? String, "My App")
        expectNoDifference(appPlist["NSCameraUsageDescription"] as? String, "Take a photo")
        expectNoDifference(appPlist["CFBundleIconFile"] as? String, "Icon")
        expectNoDifference(appPlist["UISupportedInterfaceOrientations"] as? [String],
                           ["UIInterfaceOrientationLandscapeLeft"])
        let widgetPlist = try readPlist(widgetSettings)
        expectNoDifference(widgetPlist["NSExtension"] as? [String: String],
                           ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"])
        #expect(widgetPlist["CFBundleExecutable"] == nil)
        #expect(widgetPlist["CFBundlePackageType"] == nil)
        // Verify the build service receives the phases and references through PIF serialization.
        let roundTrip = try XPIF.Container(data: description.data())
        expectNoDifference(roundTrip.workspace.projects.flatMap(\.targets).map(\.common.buildPhases),
                           description.workspace.projects.flatMap(\.targets).map(\.common.buildPhases))
    }

    @Test func delegatesPlistDefaultsToSwiftBuild() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let description = try describe(schema: .default, root: root, products: ["App"])
        let app = try #require(description.workspace.projects.first?.targets.first { $0.id == "xtool:main-app" })
        let settings = try #require(app.common.buildConfigs.first?.settings)
        #expect(settings[.INFOPLIST_FILE] == nil)
        expectNoDifference(settings[.GENERATE_INFOPLIST_FILE], "YES")
        expectNoDifference(settings[.CURRENT_PROJECT_VERSION], "1")
        expectNoDifference(settings[.MARKETING_VERSION], "1.0.0")
        expectNoDifference(settings[.PRODUCT_NAME], "App")
        #expect(settings[single: "EXECUTABLE_NAME"] == nil)
        #expect(settings[single: "INFOPLIST_KEY_CFBundleName"] == nil)
        expectNoDifference(settings[multiple: "INFOPLIST_KEY_UISupportedInterfaceOrientations[sdk=iphone*]"],
                           ["UIInterfaceOrientationPortrait"])
        expectNoDifference(settings[single: "INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphone*]"], "YES")
        expectNoDifference(settings[multiple: "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad[sdk=iphone*]"], [
            "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
        ])
    }

    private func describe(schema: PackSchema, root: URL, products: [String]) throws -> XPIF.Container {
        let project = XPIF.Project(
            id: "package", path: root.appending(path: "Package.swift").path, projectDir: root.path, name: "Package",
            targets: products.map { name in
                .target(.init(id: .init("PACKAGE-PRODUCT:\(name)"), productType: .packageProduct,
                              name: "\(name)-product", productName: name))
            }
        )
        let pif = XPIF.Container(workspace: .init(id: "workspace", name: "Package", path: root.path, projects: [project]))
        let swiftPM = XToolProject.SwiftPM(
            base: .init(rootDirectory: root, schema: schema),
            manifest: root.appending(path: "Package.swift")
        )
        return try SwiftPMBuildDescriber(project: swiftPM).describe(basePIF: pif)
    }

    private func copyPhases(_ target: XPIF.BaseTarget) -> [XPIF.CopyFilesBuildPhase] {
        target.common.buildPhases.compactMap { phase in
            guard case .copyFiles(let phase) = phase else { return nil }
            return phase
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writePlist(_ plist: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    private func readPlist(_ settings: XPIF.BuildSettings) throws -> [String: Any] {
        let path = try #require(settings[.INFOPLIST_FILE])
        return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(filePath: path)),
                                                                   format: nil) as? [String: Any])
    }
}
