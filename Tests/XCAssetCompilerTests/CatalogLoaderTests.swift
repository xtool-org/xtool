import Foundation
import Testing
import XUtils
@testable import XCAssetCompiler

@Suite("CatalogLoader")
struct CatalogLoaderTests {
    @Test("Rejects more than one appiconset")
    func multipleAppIconSets() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-\(UUID().uuidString).xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rootContents = """
        { "info": { "version": 1, "author": "xcode" } }
        """
        try Data(rootContents.utf8).write(to: tmp.appendingPathComponent("Contents.json"))

        let appIconJSON = """
        { "images": [], "info": { "version": 1, "author": "xcode" } }
        """

        for name in ["AppIcon.appiconset", "AltIcon.appiconset"] {
            let dir = tmp.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(appIconJSON.utf8).write(to: dir.appendingPathComponent("Contents.json"))
        }

        let loader = CatalogLoader(diagnostics: Diagnostics())
        await #expect(throws: XCAssetCompilerError.self) {
            _ = try await loader.load(catalog: tmp)
        }
    }

    @Test("Loads empty catalog")
    func empty() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let rootContents = """
        { "info": { "version": 1, "author": "xcode" } }
        """
        try Data(rootContents.utf8).write(to: tmp.appendingPathComponent("Contents.json"))

        let loader = CatalogLoader(diagnostics: Diagnostics())
        let loaded = try await loader.load(catalog: tmp)
        #expect(loaded.imageSets.isEmpty)
        #expect(loaded.colorSets.isEmpty)
        #expect(loaded.appIcon == nil)
    }
}
