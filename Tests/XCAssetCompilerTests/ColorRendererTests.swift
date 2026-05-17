import Foundation
import Testing
@testable import XCAssetCompiler

@Suite("ColorRenderer")
struct ColorRendererTests {
    @Test("Parses sRGB float components")
    func parsesFloats() throws {
        let json = """
        {
          "info": { "version": 1, "author": "xcode" },
          "colors": [
            {
              "idiom": "universal",
              "color": {
                "color-space": "srgb",
                "components": {
                  "red": "0.5", "green": "0.25", "blue": "0.75", "alpha": "1.0"
                }
              }
            }
          ]
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        let set = LoadedColorSet(
            name: "Accent",
            directory: URL(fileURLWithPath: "/"),
            contents: contents
        )
        let renditions = try ColorRenderer.renditions(for: set)
        #expect(renditions.count == 1)
        guard case .color(let body) = renditions[0].body else {
            Issue.record("expected color body")
            return
        }
        #expect(abs(body.red - 0.5) < 1e-9)
        #expect(abs(body.green - 0.25) < 1e-9)
        #expect(abs(body.blue - 0.75) < 1e-9)
        #expect(abs(body.alpha - 1) < 1e-9)
        #expect(body.colorSpaceID == 1)
    }

    @Test("Honours display-P3 gamut")
    func parsesP3() throws {
        let json = """
        {
          "info": { "version": 1, "author": "xcode" },
          "colors": [
            {
              "idiom": "universal",
              "display-gamut": "display-P3",
              "color": {
                "color-space": "display-p3",
                "components": {
                  "red": "1.0", "green": "0.0", "blue": "0.0", "alpha": "1.0"
                }
              }
            }
          ]
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        let set = LoadedColorSet(name: "P3Red", directory: URL(fileURLWithPath: "/"), contents: contents)
        let renditions = try ColorRenderer.renditions(for: set)
        #expect(renditions.count == 1)
        #expect(renditions[0].gamut == .displayP3)
        guard case .color(let body) = renditions[0].body else {
            Issue.record("expected color body")
            return
        }
        #expect(body.colorSpaceID == 2)
    }

    @Test("Parses 0x-prefixed hex components")
    func parsesHex() throws {
        let json = """
        {
          "info": { "version": 1, "author": "xcode" },
          "colors": [
            {
              "idiom": "universal",
              "color": {
                "color-space": "srgb",
                "components": {
                  "red": "0xFF", "green": "0x00", "blue": "0x80", "alpha": "1.0"
                }
              }
            }
          ]
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        let set = LoadedColorSet(name: "Hex", directory: URL(fileURLWithPath: "/"), contents: contents)
        let renditions = try ColorRenderer.renditions(for: set)
        guard case .color(let body) = renditions[0].body else {
            Issue.record("expected color body")
            return
        }
        #expect(abs(body.red - 1) < 1e-9)
        #expect(abs(body.green - 0) < 1e-9)
        #expect(abs(body.blue - 128 / 255) < 1e-9)
    }
}
