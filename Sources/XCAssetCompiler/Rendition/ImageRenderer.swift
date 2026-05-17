import Foundation
import PNG
import XUtils

enum ImageRenderer {
    static func renditions(for set: LoadedImageSet) throws -> [Rendition] {
        var out: [Rendition] = []
        for image in set.contents.images {
            guard let filename = image.filename, !filename.isEmpty else { continue }
            let src = set.directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: src.path) else {
                throw XCAssetCompilerError.missingReferencedFile(asset: set.name, filename: filename)
            }
            let (width, height, bgra) = try decodeBGRAPremultiplied(at: src)
            let gamut = image.displayGamut ?? .sRGB
            let appearance = image.appearances?.first { $0.darkLuminosity }
            out.append(Rendition(
                name: set.name,
                idiom: image.idiom,
                scale: image.scale,
                appearance: appearance,
                gamut: gamut,
                body: .bitmap(BitmapBody(
                    width: width,
                    height: height,
                    pixelsBGRA: bgra,
                    colorSpaceID: gamut.colorSpaceID,
                    kind: .image,
                    renditionName: filename
                ))
            ))
        }
        return out
    }

    static func appIconRenditions(for appIcon: LoadedAppIcon, files: [IconFile]) throws -> [Rendition] {
        var out: [Rendition] = []
        for file in files {
            let (width, height, bgra) = try decodeBGRAPremultiplied(at: file.sourceURL)
            let scale: Scale = {
                switch file.scale {
                case 1: return .x1
                case 2: return .x2
                case 3: return .x3
                default: return .x1
                }
            }()
            // Use the appiconset's basename ("AppIcon") for the rendition name
            // so it matches the reference; the per-file outputName
            // ("AppIcon60x60") is only used for CFBundleIconFiles in Info.plist.
            out.append(Rendition(
                name: appIcon.name,
                idiom: file.idiom,
                scale: scale,
                appearance: nil,
                gamut: .sRGB,
                body: .bitmap(BitmapBody(
                    width: width,
                    height: height,
                    pixelsBGRA: bgra,
                    colorSpaceID: Gamut.sRGB.colorSpaceID,
                    kind: .appIcon,
                    renditionName: file.sourceURL.lastPathComponent
                ))
            ))
        }
        return out
    }

    private static func decodeBGRAPremultiplied(at url: URL) throws -> (UInt32, UInt32, [UInt8]) {
        guard let image = try PNG.Image.decompress(path: url.path) else {
            throw XCAssetCompilerError.missingReferencedFile(asset: url.lastPathComponent, filename: url.lastPathComponent)
        }
        let rgba: [PNG.RGBA<UInt8>] = image.unpack(as: PNG.RGBA<UInt8>.self)
        let width = UInt32(image.size.x)
        let height = UInt32(image.size.y)
        var out = [UInt8](repeating: 0, count: rgba.count * 4)
        for i in 0..<rgba.count {
            let px = rgba[i]
            let a = UInt16(px.a)
            let r = UInt8((UInt16(px.r) * a + 127) / 255)
            let g = UInt8((UInt16(px.g) * a + 127) / 255)
            let b = UInt8((UInt16(px.b) * a + 127) / 255)
            let base = i * 4
            out[base + 0] = b
            out[base + 1] = g
            out[base + 2] = r
            out[base + 3] = px.a
        }
        return (width, height, out)
    }
}
