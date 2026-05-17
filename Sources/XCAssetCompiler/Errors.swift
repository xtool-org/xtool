import Foundation

public enum XCAssetCompilerError: Error, Sendable, Equatable {
    case missingContentsJSON(path: String)
    case malformedContentsJSON(path: String, underlying: String)
    case missingReferencedFile(asset: String, filename: String)
    case scaleFileMissing(asset: String, scale: String)
    case invalidColorComponent(String)
    case unsupportedGamut(String)
    case multipleAppIconSets([String])
    case appIconSizeMissing(asset: String, size: String)
    case notADirectory(path: String)
    case unsupportedAssetType(String)
}

extension XCAssetCompilerError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingContentsJSON(let path):
            return "Asset is missing Contents.json: \(path)"
        case .malformedContentsJSON(let path, let underlying):
            return "Could not parse \(path): \(underlying)"
        case .missingReferencedFile(let asset, let filename):
            return "Asset '\(asset)' references missing file '\(filename)'"
        case .scaleFileMissing(let asset, let scale):
            return "Asset '\(asset)' declares scale \(scale) but no file is present for it"
        case .invalidColorComponent(let s):
            return "Invalid color component: '\(s)'"
        case .unsupportedGamut(let g):
            return "Unsupported display-gamut: '\(g)' (expected sRGB or display-P3)"
        case .multipleAppIconSets(let names):
            return "Catalog has more than one .appiconset: \(names.joined(separator: ", "))"
        case .appIconSizeMissing(let asset, let size):
            return "AppIcon '\(asset)' declares size \(size) but no source file matched"
        case .notADirectory(let path):
            return "Expected an .xcassets directory at \(path)"
        case .unsupportedAssetType(let name):
            return "Unsupported asset type: \(name)"
        }
    }
}
