import Foundation
import Testing
import XUtils
@testable import XCAssetCompiler

@Suite("CARWriter")
struct CARWriterTests {
    @Test("Empty rendition list produces a structurally valid BOM")
    func emptyWriter() throws {
        let writer = CARWriter(deploymentTarget: "16.0", renditions: [])
        let data = try writer.write()
        let bytes = [UInt8](data)
        #expect(Array(bytes.prefix(8)) == Array("BOMStore".utf8))
    }

    @Test("End-to-end compile from a small in-memory catalog produces a non-empty .car")
    func endToEnd() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString).xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data("""
        { "info": { "version": 1, "author": "xcode" } }
        """.utf8).write(to: tmp.appendingPathComponent("Contents.json"))

        let colorSet = tmp.appendingPathComponent("Accent.colorset", isDirectory: true)
        try FileManager.default.createDirectory(at: colorSet, withIntermediateDirectories: true)
        try Data("""
        {
          "info": { "version": 1, "author": "xcode" },
          "colors": [
            {
              "idiom": "universal",
              "color": {
                "color-space": "srgb",
                "components": { "red": "0.5", "green": "0.5", "blue": "0.5", "alpha": "1.0" }
              }
            }
          ]
        }
        """.utf8).write(to: colorSet.appendingPathComponent("Contents.json"))

        let compiler = XCAssetCompiler(deploymentTarget: "16.0", diagnostics: Diagnostics())
        let result = try await compiler.compile(catalog: tmp)
        #expect(result.carData.count > 600)
        #expect(Array(result.carData.prefix(8)) == Array("BOMStore".utf8))
        #expect(result.primaryIconName == nil)
    }
}
