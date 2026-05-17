import Foundation
import Testing
@testable import XCAssetCompiler

@Suite("AppIconPlist")
struct AppIconPlistTests {
    @Test("Honours the .appiconset basename as CFBundleIconName")
    func iconNameIsBasename() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyIcon-\(UUID().uuidString).appiconset", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let png = solidPNG()
        try png.write(to: tmp.appendingPathComponent("Icon-60@2x.png"))
        try png.write(to: tmp.appendingPathComponent("Icon-60@3x.png"))

        let json = """
        {
          "images" : [
            {
              "idiom" : "iphone",
              "size" : "60x60",
              "scale" : "2x",
              "filename" : "Icon-60@2x.png"
            },
            {
              "idiom" : "iphone",
              "size" : "60x60",
              "scale" : "3x",
              "filename" : "Icon-60@3x.png"
            }
          ],
          "info" : { "version" : 1, "author" : "xcode" }
        }
        """
        try Data(json.utf8).write(to: tmp.appendingPathComponent("Contents.json"))

        let decoder = JSONDecoder()
        let contents = try decoder.decode(
            AppIconContents.self,
            from: Data(contentsOf: tmp.appendingPathComponent("Contents.json"))
        )
        let basename = tmp.deletingPathExtension().lastPathComponent
        let appIcon = LoadedAppIcon(name: basename, directory: tmp, contents: contents)
        let result = try AppIconPlistEmitter.emit(appIcon)

        #expect(result.iconName == basename)
        let topLevelName = result.infoPlistAdditions["CFBundleIconName"] as? String
        #expect(topLevelName == basename)

        let icons = result.infoPlistAdditions["CFBundleIcons"] as? [String: any Sendable]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: any Sendable]
        let primaryName = primary?["CFBundleIconName"] as? String
        #expect(primaryName == basename)
        let files = primary?["CFBundleIconFiles"] as? [String]
        #expect(files?.contains("\(basename)60x60") == true)
    }

    @Test("Rejects appicon entry missing filename")
    func missingFilenameThrows() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppIcon-\(UUID().uuidString).appiconset", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = """
        {
          "images" : [
            { "idiom" : "iphone", "size" : "60x60", "scale" : "2x" }
          ],
          "info" : { "version" : 1, "author" : "xcode" }
        }
        """
        try Data(json.utf8).write(to: tmp.appendingPathComponent("Contents.json"))
        let contents = try JSONDecoder().decode(
            AppIconContents.self,
            from: Data(contentsOf: tmp.appendingPathComponent("Contents.json"))
        )
        let appIcon = LoadedAppIcon(name: "AppIcon", directory: tmp, contents: contents)
        #expect(throws: XCAssetCompilerError.self) {
            _ = try AppIconPlistEmitter.emit(appIcon)
        }
    }
}

// Smallest possible valid PNG (1x1 transparent)
private func solidPNG() -> Data {
    let bytes: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
    ]
    return Data(bytes)
}
