import Foundation
import XcodeProjects
import XPIF
import Testing
@testable import XcodePIFConversion

struct XcodeSynchronizedFolderTests {
    @Test(arguments: [XcodeProject.Format.pbxproj, .xcproj])
    func discoversFilesAndAppliesMembershipExceptions(format: XcodeProject.Format) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = try project(at: directory)
        source.format = format
        var folder = synchronizedFolder()
        folder.explicitFileTypes = ["Custom.txt": .init(rawValue: "sourcecode.swift")]
        folder.explicitOpaqueFolders = ["Opaque"]
        folder.membershipExceptions = [
            .target(.init(target: .init(targetName: "Probe"), publicHeaders: ["Public.hpp"], privateHeaders: [],
                          additionalCompilerFlags: ["Nested/Code.swift": "-DTEST"], commonProperties: common(
                            sense: .exclusions, members: ["Excluded.swift", "Settings.xcconfig"],
                            filters: ["Nested/Code.swift": [.init(rawValue: "maccatalyst")]]
                          ))),
            .target(.init(target: .init(targetName: "Extra"), publicHeaders: [], privateHeaders: [],
                          additionalCompilerFlags: [:], commonProperties: common(sense: .inclusions, members: ["Excluded.swift"]))),
            .buildPhase(.init(buildPhase: .named(target: .init(targetName: "Probe"), kind: .copy, name: "Copy"),
                              commonProperties: common(sense: .inclusions, members: ["Data.json"],
                                                       tags: format == .xcproj ? ["Data.json": [.init(rawValue: "asset")]] : [:]))),
        ]
        source.project.topLevelReferences[0] = .folder(folder)
        var extra = source.project.targets[0].commonProperties
        extra.name = "Extra"
        extra.objectID = .init("EXTRA")
        extra.specializedConfigurations = []
        extra.product = nil
        extra.buildPhases = [.sources(.init(objectID: nil, name: nil))]
        source.project.targets.append(.aggregate(extra))
        source.project.configurations[0].file = .init(
            anchor: .objectID(.init("SYNC")), relativePath: .init(components: [.child("Settings.xcconfig")])
        )
        try writeFiles([
            "Nested/Code.swift", "Excluded.swift", "Public.hpp", "Custom.txt", "Data.json", "Settings.xcconfig",
            "Opaque/Hidden.swift", "Assets.xcassets/Contents.json", "Models.xcdatamodeld/Model.xcdatamodel/contents",
            "Support.framework/Support", "lib.a", ".hidden.swift", "App.entitlements", "module.modulemap",
            "Demo.playground/Contents.swift", "Backup.swift~",
        ], at: directory)
        try source.write()
        let result = try XcodePIFBuilder(project: XcodeProject(url: source.url)).build().projects[0]
        let files = fileReferences(in: result.mainGroup)
        let app = result.targets[0].common
        #expect(Set(paths(in: app.buildPhases[0], files: files)) == ["Code.swift", "Custom.txt", "Models.xcdatamodeld"])
        #expect(paths(in: app.buildPhases[1], files: files) == ["Public.hpp"])
        #expect(Set(paths(in: app.buildPhases[2], files: files)) == ["Assets.xcassets", "Data.json", "Opaque"])
        #expect(Set(paths(in: app.buildPhases[3], files: files)) == ["Support.framework", "lib.a"])
        #expect(paths(in: app.buildPhases[4], files: files) == ["Data.json"])
        #expect(paths(in: result.targets[1].common.buildPhases[0], files: files) == ["Excluded.swift"])
        #expect(files.values.allSatisfy { !$0.hasSuffix("Hidden.swift") && !$0.hasSuffix("Contents.json") })
        #expect(!files.values.contains(".hidden.swift") && !files.values.contains("Backup.swift~"))
        guard case .sources(let sources) = app.buildPhases[0], case .headers(let headers) = app.buildPhases[1],
              case .copyFiles(let copy) = app.buildPhases[4] else {
            Issue.record("Missing synchronized folder phases")
            return
        }
        let compiled = try #require(sources.files.first(where: { filePath($0, files: files) == "Code.swift" }))
        #expect(compiled.additionalCompilerOptions == .string("-DTEST"))
        #expect(compiled.platformFilters == [.init(platform: "ios", environment: "maccatalyst")])
        #expect(headers.files.first?.headerVisibility == .public)
        #expect(copy.files.first?.assetTags == (format == .xcproj ? ["asset"] : []))
        #expect(result.buildConfigs[0].baseConfigurationFileReference == files.first(where: { $0.value == "Settings.xcconfig" })?.key)
        let data = try XPIF.Container(workspace: XcodePIFBuilder(project: source).build()).data()
        #expect(try XPIF.Container(data: data).data() == data)
    }

    @Test func groupsLocalizedResourcesAndPreservesDiscoveredIdentifiers() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = try project(at: directory)
        var folderSource = synchronizedFolder()
        folderSource.membershipExceptions = [.target(.init(
            target: .init(targetName: "Probe"), publicHeaders: [], privateHeaders: [], additionalCompilerFlags: [:],
            commonProperties: common(sense: .exclusions, members: ["en.lproj/Main.strings"])
        ))]
        source.project.topLevelReferences[0] = .folder(folderSource)
        try writeFiles(["Nested/Code.swift", "Base.lproj/Main.storyboard", "en.lproj/Main.strings", "fr.lproj/Main.strings",
                        "en.lproj/Localizable.strings", "fr.lproj/Localizable.strings"], at: directory)
        let result = try XcodePIFBuilder(project: source).build().projects[0]
        guard case .group(let folder) = result.mainGroup.subitems[0] else {
            Issue.record("Missing expanded folder")
            return
        }
        #expect(result.knownRegions == ["Base", "en", "fr"])
        let variants = folder.subitems.compactMap { reference -> XPIF.Group? in
            guard case .group(let group) = reference, group.kind == .variantGroup else { return nil }
            return group
        }
        #expect(Set(variants.map(\.name)) == ["Main.storyboard", "Localizable.strings"])
        let main = try #require(variants.first(where: { $0.name == "Main.storyboard" }))
        let regions = main.subitems.compactMap { reference -> String? in
            guard case .file(let file) = reference else { return nil }
            return file.regionVariantName
        }
        #expect(Set(regions) == ["Base", "en", "fr"])
        guard case .copyBundleResources(let resources) = result.targets[0].common.buildPhases[2] else {
            Issue.record("Missing resources phase")
            return
        }
        #expect(Set(resources.files.map(\.ref)) == Set(variants.map { .reference(id: $0.id) }))
        let originalFiles = fileReferences(in: result.mainGroup)
        try writeFiles(["AAA.swift"], at: directory)
        let updated = try XcodePIFBuilder(project: source).build().projects[0]
        let updatedFiles = fileReferences(in: updated.mainGroup)
        #expect(originalFiles.allSatisfy { updatedFiles[$0.key] == $0.value })
    }

    @Test func rejectsUnresolvedMembershipsAndDirectoryCycles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = try project(at: directory)
        try writeFiles(["Code.swift"], at: directory)
        var folder = synchronizedFolder()
        folder.targets = [.init(targetName: "Missing")]
        source.project.topLevelReferences[0] = .folder(folder)
        #expect(throws: XcodePIFConversionError.self) { try XcodePIFBuilder(project: source).build() }
        folder.targets = [.init(targetName: "Probe")]
        folder.membershipExceptions = [.buildPhase(.init(
            buildPhase: .objectID(.init("MISSING")), commonProperties: common(sense: .inclusions, members: [])
        ))]
        source.project.topLevelReferences[0] = .folder(folder)
        #expect(throws: XcodePIFConversionError.self) { try XcodePIFBuilder(project: source).build() }
        source.project.topLevelReferences[0] = .folder(synchronizedFolder())
        try FileManager.default.createSymbolicLink(
            at: directory.appending(path: "Files/Loop"), withDestinationURL: directory.appending(path: "Files")
        )
        #expect(throws: XcodePIFConversionError.self) { try XcodePIFBuilder(project: source).build() }
    }

    @Test func discoversUnattachedFoldersRelativeToGroupsAndSourceRoot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = try project(at: directory)
        try FileManager.default.createDirectory(at: source.url, withIntermediateDirectories: true)
        try source.project.pbxprojRepresentation(name: "Probe", projectDirPath: "SourceRoot")
            .write(to: source.url.appending(path: "project.pbxproj"))
        source = try XcodeProject(url: source.url)
        var folder = synchronizedFolder()
        folder.targets = []
        source.project.topLevelReferences[0] = .group(.init(
            objectID: nil, name: "Outer", path: "Parent", includeInIndex: nil, children: [.folder(folder)]
        ))
        let empty = try XcodePIFBuilder(project: source).build().projects[0]
        #expect(fileReferences(in: empty.mainGroup).isEmpty)
        try writeFiles(["Nested/Settings.xcconfig", "Code.swift"], at: directory.appending(path: "SourceRoot/Parent"))
        source.project.configurations[0].file = .init(
            anchor: .objectID(.init("SYNC")), relativePath: .init(components: [.child("Nested"), .child("Settings.xcconfig")])
        )
        let result = try XcodePIFBuilder(project: source).build().projects[0]
        let files = fileReferences(in: result.mainGroup)
        #expect(Set(files.values) == ["Settings.xcconfig", "Code.swift"])
        #expect(result.buildConfigs[0].baseConfigurationFileReference == files.first(where: { $0.value == "Settings.xcconfig" })?.key)
        #expect(paths(in: result.targets[0].common.buildPhases[0], files: files).isEmpty)
    }

    // Expectations match `xcodebuild -dumpPIF` for the same type and phase layout.
    @Test(arguments: [
        ("text.plist.entitlements", "SR", nil), ("text.plist.entitlements", "C", .copy),
        ("sourcecode.module-map", "HSFR", nil), ("file.playground", "SR", nil), ("sourcecode.typescript", "SR", nil),
        ("net.daringfireball.markdown", "SR", .resources), ("sourcecode.javascript", "SR", .resources),
        ("text.apinotes", "SR", nil), ("text.apinotes", "HSFR", .headers),
        ("sourcecode.text-based-dylib-definition", "HSFR", .frameworks), ("sourcecode.text-based-dylib-definition", "SR", nil),
        ("file.intentdefinition", "SR", .sources), ("file.intentdefinition", "R", .resources), ("archive.ppob", "R", .resources),
        ("archive.ppob", "S", nil), ("wrapper.xcdatamodeld", "SR", .sources), ("sourcecode.swift", "R", nil),
        ("sourcecode.swift", "RS", .sources), ("sourcecode.swift", "CX", .copy), ("sourcecode.swift", "CCX", nil),
        ("sourcecode.swift", "CR", nil), ("image.png", "CR", .resources), ("image.png", "S", nil),
        ("wrapper.pb-project", "C", nil), ("sourcecode.swift", "metal:SR", nil), ("sourcecode.metal", "metal:SR", .sources),
    ] as [(String, String, XCSchema.BuildPhase.Kind?)])
    func routesImplicitMembersLikeXcode(fileType: String, layout: String, expected: XCSchema.BuildPhase.Kind?) throws {
        var target = try project(at: URL(filePath: "/")).project.targets[0].commonProperties
        let parts = layout.split(separator: ":")
        if parts.count > 1 { target.productTypeID = .init(abbreviatedRepresentation: "metal-library") }
        target.buildPhases = parts.last!.map { letter -> XCSchema.BuildPhase in
            switch letter {
            case "S": .sources(.init(objectID: nil, name: nil))
            case "H": .headers(.init(objectID: nil, name: nil))
            case "F": .frameworks(.init(objectID: nil, name: nil))
            case "R": .resources(.init(objectID: nil, name: nil))
            case "C": .copy(.init(objectID: nil, name: nil, bundleBasePath: .resourcesDir, relativePath: "", scope: .always))
            default: .script(.init(
                objectID: nil, name: "Script", shellPath: "/bin/sh", script: "", logEnvironmentVariables: false,
                inputPaths: [], inputFileListPaths: [], outputPaths: [], outputFileListPaths: [], dependencyFile: nil,
                runOnEveryBuild: false, scope: .always
            ))
            }
        }
        #expect(XcodeSynchronizedFolder.implicitPhase(for: XcodeFileType(identifier: fileType), in: target)?.kind == expected)
    }

    @Test func detectsFileTypesLikeXcode() {
        #expect(XcodeFileType.forFile(named: "x.h")?.identifier == "sourcecode.c.h")
        #expect(XcodeFileType.forFile(named: "x.H")?.identifier == "sourcecode.cpp.h")
        #expect(XcodeFileType.forFile(named: "X.SWIFT")?.identifier == "sourcecode.swift")
        #expect(XcodeFileType.forFile(named: "App.entitlements")?.identifier == "text.plist.entitlements")
        #expect(XcodeFileType.forFile(named: "Makefile")?.identifier == "sourcecode.make")
        #expect(XcodeFileType.forFile(named: "Demo.playground") == nil)
        #expect(XcodeFileType.forFile(named: "data.unknown") == nil)
        #expect(XcodeFileType.forDirectory(named: "Demo.playground")?.identifier == "file.playground")
        #expect(XcodeFileType.forDirectory(named: "Assets.xcassets")?.identifier == "folder.assetcatalog")
        #expect(XcodeFileType.forDirectory(named: "Sources.swift") == nil)
        #expect(XcodeFileType(identifier: "text.plist.strings").ancestry.map(\.identifier)
            == ["text.plist.strings", "text", "file"])
    }

    @Test func collectsKnownFileTypes() {
        // Spot-check `@CollectXcodeFileTypes` with the first, a middle, and the last declared type.
        #expect(XcodeFileType.all.contains(.archive))
        #expect(XcodeFileType.all.contains(.sourcecodeIig))
        #expect(XcodeFileType.all.contains(.wrapperXpcService))
    }

    private func project(at directory: URL) throws -> XcodeProject {
        let fixture = fixtureURL("simple-xcode-project.pbxproj")
        var source = try XcodeProject(project: .init(pbxprojRepresentation: Data(contentsOf: fixture)),
                                      url: directory.appending(path: "Probe.xcodeproj"))
        source.project.topLevelReferences[0] = .folder(synchronizedFolder())
        var target = source.project.targets[0].commonProperties
        target.buildPhases = [
            .sources(.init(objectID: nil, name: nil)), .headers(.init(objectID: nil, name: nil)),
            .resources(.init(objectID: nil, name: nil)), .frameworks(.init(objectID: nil, name: nil)),
            .copy(.init(objectID: nil, name: "Copy", bundleBasePath: .resourcesDir, relativePath: "", scope: .always)),
        ]
        source.project.targets[0] = .native(target)
        return source
    }

    private func synchronizedFolder() -> XCSchema.Folder {
        .init(objectID: .init("SYNC"), path: "Files", targets: [.init(targetName: "Probe")], membershipExceptions: [],
              explicitFileTypes: [:], explicitOpaqueFolders: [], includeInIndex: nil)
    }

    private func common(
        sense: XCSchema.ExceptionSetSense, members: Set<XCSchema.FolderMemberID>,
        filters: [XCSchema.FolderMemberID: Set<XCSchema.PlatformFilter>] = [:],
        tags: [XCSchema.FolderMemberID: Set<XCSchema.AssetTag>] = [:]
    ) -> XCSchema.CommonExceptionSetProperties {
        .init(sense: sense, membershipExceptions: members, platformFiltersByFolderMemberID: filters,
              attributesByFolderMemberID: [:], assetTagsByFolderMemberID: tags)
    }

    private func writeFiles(_ paths: [String], at directory: URL) throws {
        for path in paths {
            let url = directory.appending(path: "Files/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fileReferences(in group: XPIF.Group) -> [XPIF.GUID: String] {
        var result: [XPIF.GUID: String] = [:]
        for reference in group.subitems {
            switch reference {
            case .file(let file): result[file.id] = file.path
            case .group(let child):
                result.merge(fileReferences(in: child)) { _, new in new }
                if child.kind == .versionGroup { result[child.id] = child.path }
            }
        }
        return result
    }

    private func paths(in phase: XPIF.BuildPhase, files: [XPIF.GUID: String]) -> [String] {
        switch phase {
        case .sources(let phase): phase.files.compactMap { filePath($0, files: files) }
        case .headers(let phase): phase.files.compactMap { filePath($0, files: files) }
        case .frameworks(let phase): phase.files.compactMap { filePath($0, files: files) }
        case .copyBundleResources(let phase): phase.files.compactMap { filePath($0, files: files) }
        case .copyFiles(let phase): phase.files.compactMap { filePath($0, files: files) }
        default: []
        }
    }

    private func filePath(_ file: XPIF.BuildFile, files: [XPIF.GUID: String]) -> String? {
        guard case .reference(let id) = file.ref else { return nil }
        return files[id]
    }
}
