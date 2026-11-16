import Foundation
import CustomDump
import XcodeProjects
import XPIF
import Testing
import SwiftBuild
@testable import XToolSupport
@testable import XcodePIFConversion

struct XcodeWorkspacePIFBuilderTests {
    @Test(arguments: [XcodeProject.Format.pbxproj, .xcproj])
    func resolvesCrossProjectDependenciesAndProducts(format: XcodeProject.Format) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeGraph(at: directory, format: format)
        let workspace = try XcodePIFBuilder(workspace: XcodeWorkspace(url: url)).build()
        #expect(workspace.name == "App")
        #expect(workspace.path == url.path)
        #expect(workspace.projects.map(\.name) == ["App", "Support"])
        let app = workspace.projects[0].targets[0]
        let support = workspace.projects[1].targets[0]
        #expect(app.id != support.id) // The fixtures deliberately reuse the original target and product IDs.
        var dependency = XPIF.TargetDependency(targetId: support.id, platformFilters: [.init(platform: "ios")])
        dependency.additionalFields["name"] = .string("Support (from Support.xcodeproj)")
        #expect(app.common.dependencies == [dependency])
        guard case .frameworks(let link) = app.common.buildPhases[1],
              case .copyFiles(let embed) = app.common.buildPhases[2] else {
            Issue.record("Expected link and embed phases")
            return
        }
        #expect(link.files.first?.ref == .targetProduct(id: support.id))
        #expect(link.files.first?.shouldLinkWeakly == true)
        #expect(embed.files.first?.ref == .targetProduct(id: support.id))
        #expect(embed.files.first?.codeSignOnCopy == true)
        let standalone = try XcodePIFBuilder(project: XcodeProject(url: directory.appending(path: "App.xcodeproj"))).build()
        #expect(standalone.name == "App")
        #expect(standalone.projects.map(\.id) == workspace.projects.map(\.id))
        let explicitlyNamed = try XcodeWorkspace(url: url).withURL(directory.appending(path: "project.xcworkspace"))
        #expect(try XcodePIFBuilder(workspace: explicitlyNamed).build().name == "project")
        let data = try XPIF.Container(workspace: workspace).data()
        #expect(try XPIF.Container(data: data).data() == data)
        #expect(try XPIF.Container(workspace: XcodePIFBuilder(workspace: XcodeWorkspace(url: url)).build()).data() == data)
    }

    @Test func loadedProjectsCanBeReusedByIndependentBuilders() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeGraph(at: directory, format: .pbxproj)
        let graph = try XcodePIFBuilder(workspace: XcodeWorkspace(url: url))
        var workspace = try graph.build()
        let loaded = try #require(graph.projects.values.first)
        let reservedIDs = loaded.usedIDs
        var first = XcodePIFProjectBuilder(loaded: loaded)
        workspace.projects[0] = try first.buildProject(in: graph.projects)
        let firstData = try XPIF.Container(workspace: workspace).data()
        var second = XcodePIFProjectBuilder(loaded: loaded)
        workspace.projects[0] = try second.buildProject(in: graph.projects)
        #expect(try XPIF.Container(workspace: workspace).data() == firstData)
        #expect(loaded.usedIDs == reservedIDs)
        #expect(first.usedIDs.count > reservedIDs.count)
        #expect(second.usedIDs == first.usedIDs)
    }

    @Test func loadsSharedReferencesAndCyclesOnce() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeGraph(at: directory, format: .xcproj)
        let supportURL = directory.appending(path: "Libraries/Support.xcodeproj")
        var support = try XcodeProject(url: supportURL)
        support.project.topLevelReferences.append(.fileReference(file(path: "../App.xcodeproj")))
        try support.write()
        var workspace = try XcodeWorkspace(url: url)
        workspace.children.append(.file(.init(base: .group, path: "Libraries/../Libraries/Support.xcodeproj")))
        let alias = directory.appending(path: "Alias.xcodeproj")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: supportURL)
        workspace.children.append(.file(.init(base: .absolute, path: alias.path)))
        let result = try XcodePIFBuilder(workspace: workspace).build()
        #expect(result.projects.count == 2)
        let embedded = try XcodeWorkspace(url: directory.appending(path: "App.xcodeproj/project.xcworkspace"))
        #expect(try XcodePIFBuilder(workspace: embedded).build().projects.count == 2)
    }

    @Test func rejectsMissingProjectsAndStaleForeignIDs() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeGraph(at: directory, format: .xcproj)
        let appURL = directory.appending(path: "App.xcodeproj")
        var app = try XcodeProject(url: appURL)
        app.project.importedProducts[0].productID = .init("MISSING_PRODUCT")
        #expect(throws: XcodePIFConversionError.self) { try XcodePIFBuilder(project: app).build() }
        app = try XcodeProject(url: appURL)
        var target = app.project.targets[0].commonProperties
        target.dependencies = [.remoteTarget(.init(
            project: remoteReference, target: "Support", targetID: .init("MISSING_TARGET")
        ), [])]
        app.project.targets[0] = .native(target)
        #expect(throws: XcodePIFConversionError.self) { try XcodePIFBuilder(project: app).build() }
        try FileManager.default.removeItem(at: directory.appending(path: "Libraries/Support.xcodeproj"))
        #expect(throws: (any Error).self) { try XcodePIFBuilder(workspace: XcodeWorkspace(url: url)).build() }
    }

    @Test(arguments: [XcodeProject.Format.pbxproj, .xcproj])
    func resolvesProjectPathsFromItsRequiredURL(format: XcodeProject.Format) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeGraph(at: directory, format: format)
        let app = try XcodeProject(url: directory.appending(path: "App.xcodeproj"))
        expectNoDifference(app.sourceRoot.path, directory.path)
        let result = try XcodePIFBuilder(project: app).build()
        #expect(result.projects[0].projectDir == app.url.deletingLastPathComponent().path)
        #expect(result.projects[1].projectDir == directory.appending(path: "Libraries").path)
        #expect(result.projects.count == 2)
        #expect(app.resolve("<PROJECT>/Libraries/Support.xcodeproj", relativeTo: nil)?.path
                == directory.appending(path: "Libraries/Support.xcodeproj").path)
        let copyURL = directory.appending(path: "Exports/App.xcodeproj")
        try app.withURL(copyURL).write()
        let copy = try XcodeProject(url: copyURL)
        expectNoDifference(copy.sourceRoot.path, copyURL.deletingLastPathComponent().path)
        #expect(copy.resolve("<PROJECT>/App.swift", relativeTo: nil)?.path
                == copyURL.deletingLastPathComponent().appending(path: "App.swift").path)
    }

    @Test(arguments: ["Sources", "./Sources", "Nested/../Sources"])
    func loadsAndPreservesDistinctSourceRoot(projectDirPath: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeGraph(at: directory, format: .pbxproj)
        let projectURL = directory.appending(path: "App.xcodeproj")
        let pbxprojURL = projectURL.appending(path: "project.pbxproj")
        let contents = try String(contentsOf: pbxprojURL, encoding: .utf8)
            .replacingOccurrences(of: "projectDirPath = \"\";", with: "projectDirPath = \"\(projectDirPath)\";")
        try contents.write(to: pbxprojURL, atomically: true, encoding: .utf8)
        let root = directory.appending(path: "Sources")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: directory.appending(path: "Libraries"), to: root.appending(path: "Libraries"))
        let app = try XcodeProject(url: projectURL)
        #expect(app.sourceRoot.path == root.path)
        let result = try XcodePIFBuilder(project: app).build()
        #expect(result.projects[0].projectDir == root.path)
        #expect(result.projects[1].projectDir == root.appending(path: "Libraries").path)
        try app.write()
        #expect(try XcodeProject(url: projectURL).sourceRoot.path == root.path)
        expectNoDifference(try savedProjectDirPath(at: projectURL), projectDirPath)
        let copyURL = directory.appending(path: "Exports/Copy.xcodeproj")
        let copy = app.withURL(copyURL)
        try copy.write()
        #expect(app.url.path == projectURL.path)
        let copyRoot = copyURL.deletingLastPathComponent().appending(path: "Sources")
        expectNoDifference(copy.sourceRoot.path, copyRoot.path)
        expectNoDifference(try XcodeProject(url: copyURL).sourceRoot.path, copyRoot.path)
        expectNoDifference(try savedProjectDirPath(at: copyURL), projectDirPath)
        let workspaceURL = copyURL.appending(path: "project.xcworkspace")
        let workspace = try XcodeWorkspace(url: workspaceURL)
        let exportedURL = directory.appending(path: "Exported.xcworkspace")
        try workspace.withURL(exportedURL).write()
        #expect(workspace.url.path == workspaceURL.path)
        #expect(try XcodeWorkspace(url: exportedURL).children == workspace.children)
        // Saving and then moving the checkout must keep relative source roots portable.
        let destination = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let checkout = destination.appending(path: "Checkout")
        try FileManager.default.moveItem(at: directory, to: checkout)
        let relocated = try XcodeProject(url: checkout.appending(path: "App.xcodeproj"))
        expectNoDifference(relocated.sourceRoot.path, checkout.appending(path: "Sources").path)
    }

    private func savedProjectDirPath(at url: URL) throws -> String {
        let data = try Data(contentsOf: url.appending(path: "project.pbxproj"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let rootObject = try #require(plist["rootObject"] as? String)
        let objects = try #require(plist["objects"] as? [String: [String: Any]])
        return try #require(objects[rootObject]?["projectDirPath"] as? String)
    }

    // TODO: needs an installed Darwin SDK on Linux
    #if os(macOS)
    @Test(.requiresXcode, arguments: [false, true], [false, true])
    func buildsWorkspaceWithLinkedAndEmbeddedFramework(
        implicitDependency: Bool,
        synchronizedFolders: Bool
    ) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeGraph(at: directory, format: .pbxproj)
        if synchronizedFolders {
            try synchronizeSources(in: directory.appending(path: "App.xcodeproj"))
            try synchronizeSources(in: directory.appending(path: "Libraries/Support.xcodeproj"))
        }
        if implicitDependency {
            let appURL = directory.appending(path: "App.xcodeproj")
            var app = try XcodeProject(url: appURL)
            var target = app.project.targets[0].commonProperties
            target.dependencies = []
            app.project.targets[0] = .native(target)
            try app.write()
        }
        #if os(macOS)
        let triple = "arm64-apple-ios-simulator"
        #else
        let triple = "arm64-apple-ios"
        #endif
        let description = try await XToolProject.testXcode(url).describe(configuration: .debug, triple: triple)
        let coordinator = try await BuildCoordinator(description: description)
        do {
            let guid = try await coordinator.mainProductGUID()
            let details = try await coordinator.mainProductDetails()
            #expect(details.output.lastPathComponent == "CustomApp.app")
            var request = await coordinator.buildRequest
            request.configuredTargets = [
                SWBConfiguredTarget(guid: guid),
            ]
            request.parameters.overrides.synthesized?.set(value: "NO", for: "CODE_SIGNING_ALLOWED")
            request.parameters.overrides.synthesized?.set(value: "NO", for: "COMPILER_INDEX_STORE_ENABLE")
            let derived = directory.appending(path: "DerivedData")
            request.parameters.arenaInfo = SWBArenaInfo(
                derivedDataPath: derived.path, buildProductsPath: derived.appending(path: "Products").path,
                buildIntermediatesPath: derived.appending(path: "Intermediates").path, pchPath: derived.path,
                indexRegularBuildProductsPath: nil, indexRegularBuildIntermediatesPath: nil,
                indexPCHPath: derived.path, indexDataStoreFolderPath: nil, indexEnableDataStore: false
            )
            let manager = await coordinator.sessionManager
            let output = URL(filePath: try await manager.session.evaluateMacroAsString(
                "TARGET_BUILD_DIR", level: .target(guid),
                buildParameters: request.parameters, overrides: nil
            ))
            let operation = try await manager.createBuildOperation(request: request)
            var errors: [String] = []
            for await event in try await operation.start() {
                if case .diagnostic(let diagnostic) = event, diagnostic.kind == .error {
                    errors.append(diagnostic.message)
                }
            }
            await operation.waitForCompletion()
            #expect(operation.state == .succeeded, "Build errors: \(errors)")
            #expect(FileManager.default.fileExists(atPath: output.appending(path: "CustomApp.app/CustomApp").path))
            let embeddedBinary = output.appending(path: "CustomApp.app/Frameworks/Support.framework/Support")
            #expect(FileManager.default.fileExists(atPath: embeddedBinary.path))
            if synchronizedFolders {
                #expect(FileManager.default.fileExists(atPath: output.appending(path: "CustomApp.app/Resource.txt").path))
                #expect(FileManager.default.fileExists(atPath: output
                    .appending(path: "CustomApp.app/fr.lproj/Localizable.strings").path))
                #expect(FileManager.default.fileExists(atPath: embeddedBinary.deletingLastPathComponent()
                    .appending(path: "Resource.txt").path))
            }
            await coordinator.close()
        } catch {
            await coordinator.close()
            throw error
        }
    }
    #endif

    private var remoteReference: XCSchema.GroupTreeReference {
        .namePath(.init(components: [.child("Projects"), .child("Support.xcodeproj")]))
    }

    private func synchronizeSources(in url: URL) throws {
        var project = try XcodeProject(url: url)
        var target = project.project.targets[0].commonProperties
        target.buildPhases.append(.resources(.init(objectID: nil, name: nil)))
        project.project.targets[0] = .native(target)
        project.project.topLevelReferences[0] = .folder(.init(
            objectID: nil, path: "Sources", targets: [.init(targetName: target.name)], membershipExceptions: [
                .target(.init(target: .init(targetName: target.name), publicHeaders: [], privateHeaders: [],
                              additionalCompilerFlags: [:], commonProperties: .init(
                                sense: .exclusions, membershipExceptions: ["Excluded.swift"],
                                platformFiltersByFolderMemberID: [:], attributesByFolderMemberID: [:], assetTagsByFolderMemberID: [:]
                              ))),
            ], explicitFileTypes: [:], explicitOpaqueFolders: [], includeInIndex: nil
        ))
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory.appending(path: "Sources/Nested"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: directory.appending(path: "App.swift"), to: directory.appending(path: "Sources/Nested/App.swift")
        )
        try Data("resource".utf8).write(to: directory.appending(path: "Sources/Resource.txt"))
        for language in ["en", "fr"] {
            let localized = directory.appending(path: "Sources/\(language).lproj")
            try FileManager.default.createDirectory(at: localized, withIntermediateDirectories: true)
            let encoding = language == "fr" ? String.Encoding.utf16 : .utf8
            try #require("\"key\" = \"value\";".data(using: encoding)).write(to: localized.appending(path: "Localizable.strings"))
        }
        try Data("#error(\"Excluded source was compiled\")".utf8).write(to: directory.appending(path: "Sources/Excluded.swift"))
        try project.write()
    }

    /// Creates a real PBX/xcproj graph, including proxy products, in a location usable by CLI smoke tests.
    @discardableResult
    func writeGraph(at directory: URL, format: XcodeProject.Format) throws -> URL {
        let fixture = fixtureURL("simple-xcode-project.pbxproj")
        var app = try XcodeProject(project: .init(pbxprojRepresentation: Data(contentsOf: fixture)),
                                   url: directory.appending(path: "App.xcodeproj"), format: format)
        var support = app
        support.url = directory.appending(path: "Libraries/Support.xcodeproj")
        var library = support.project.targets[0].commonProperties
        library.name = "Support"
        library.productTypeID = .init(rawValue: "com.apple.product-type.framework")
        library.buildSettings = [
            "PRODUCT_NAME": .string("Support"), "DEFINES_MODULE": .string("YES"), "SKIP_INSTALL": .string("YES"),
            "PRODUCT_BUNDLE_IDENTIFIER": .string("com.example.Support"), "GENERATE_INFOPLIST_FILE": .string("YES"),
            "SWIFT_VERSION": .string("6.0"), "CODE_SIGNING_ALLOWED": .string("NO"),
        ]
        library.buildPhases = [.sources(.init(objectID: nil, name: nil))]
        support.project.targets = [.native(library)]
        support.project.productsGroup = nil
        support.project.topLevelReferences = [
            .fileReference(file(path: "App.swift", buildFiles: [membership(target: "Support", phase: .sources)])),
            .group(.init(objectID: nil, name: "Products", path: "", includeInIndex: nil, children: [
                .fileReference(file(path: "<PRODUCTS>/Support.framework", id: "670DC86C0DB18949CDB87DC1"))
            ])),
        ]
        library.product = .namePath(.init(components: [.child("Products"), .child("Support.framework")]))
        support.project.targets = [.native(library)]
        var target = app.project.targets[0].commonProperties
        target.dependencies = [.remoteTarget(.init(
            project: remoteReference, target: "OutdatedName", targetID: library.objectID
        ), [.init(rawValue: "ios")])]
        target.buildPhases += [.frameworks(.init(objectID: nil, name: nil)), .copy(.init(
            objectID: nil, name: "Embed", bundleBasePath: .frameworksDir, relativePath: "", scope: .always
        ))]
        app.project.targets = [.native(target)]
        app.project.topLevelReferences.append(.group(.init(
            objectID: nil, name: "Projects", path: "Libraries", includeInIndex: nil,
            children: [.fileReference(file(path: "Support.xcodeproj"))]
        )))
        app.project.importedProducts = [.init(
            project: remoteReference, target: "OutdatedName", productID: .init("670DC86C0DB18949CDB87DC1"),
            path: "Support.framework", fileType: .init(rawValue: "wrapper.framework"), buildFiles: [
                membership(target: "Probe", phase: .frameworks, weak: true),
                membership(target: "Probe", phase: .copy, name: "Embed", sign: true),
            ]
        )]
        try app.write()
        try support.write()
        let source = """
        import UIKit
        import Support
        @main final class App: UIResponder, UIApplicationDelegate { let value = answer() }
        """
        try Data(source.utf8).write(to: directory.appending(path: "App.swift"))
        try Data("public func answer() -> Int { 42 }\n".utf8).write(to: directory.appending(path: "Libraries/App.swift"))
        let workspaceURL = directory.appending(path: "App.xcworkspace")
        try XcodeWorkspace(children: [
            .file(.init(base: .group, path: "App.xcodeproj")),
            .group(.init(location: .init(base: .container, path: "Libraries"), name: "Libraries", children: [
                .file(.init(base: .group, path: "Support.xcodeproj")),
            ])),
        ], url: workspaceURL).write()
        return workspaceURL
    }

    private func membership(
        target: String, phase: XCSchema.BuildPhase.Kind, name: String? = nil, weak: Bool = false, sign: Bool = false
    ) -> XCSchema.ProjectBuildFile {
        .init(objectID: nil, buildPhase: .named(target: .init(targetName: target), kind: phase, name: name), properties: .init(
            platformFilters: [], additionalBuildFlags: nil, assetTags: [], attributes: .init(
                headerRole: nil, machInterfaceGeneration: nil, isWeak: weak, codeSignOnCopy: sign,
                codeGeneration: .default, headerPreservation: .keep, decompress: false, codeGenerationVisibility: nil
            )
        ))
    }

    private func file(
        path: XCSchema.FilePath, id: String? = nil, buildFiles: [XCSchema.ProjectBuildFile] = []
    ) -> XCSchema.FileReference {
        .init(objectID: id.map { XCSchema.ObjectID($0) }, path: path, explicitFileType: nil, expectedSignature: nil,
              textEncoding: nil, lineEnding: nil, includeInIndex: nil, buildFiles: buildFiles)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
