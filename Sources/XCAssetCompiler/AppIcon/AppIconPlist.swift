import Foundation

struct AppIconPlistResult: Sendable {
    var infoPlistAdditions: [String: any Sendable]
    var iconName: String
    var iconFiles: [IconFile]
}

struct IconFile: Sendable, Hashable {
    var idiom: Idiom
    var pointSize: Double
    var scale: Int
    var sourceURL: URL
    var outputName: String
}

enum AppIconPlistEmitter {
    static func emit(_ appIcon: LoadedAppIcon) throws -> AppIconPlistResult {
        var iphoneFiles: [String] = []
        var ipadFiles: [String] = []
        var allFiles: [IconFile] = []

        for image in appIcon.contents.images {
            guard let filename = image.filename, !filename.isEmpty else {
                throw XCAssetCompilerError.appIconSizeMissing(asset: appIcon.name, size: image.size)
            }
            let src = appIcon.directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: src.path) else {
                throw XCAssetCompilerError.missingReferencedFile(asset: appIcon.name, filename: filename)
            }
            guard let (w, _) = image.pointSize, let scale = image.scale?.factor else {
                throw XCAssetCompilerError.appIconSizeMissing(asset: appIcon.name, size: image.size)
            }
            let bundleName = "\(appIcon.name)\(formatSize(w))x\(formatSize(w))"
            let entry = IconFile(
                idiom: image.idiom,
                pointSize: w,
                scale: scale,
                sourceURL: src,
                outputName: bundleName
            )
            allFiles.append(entry)
            switch image.idiom {
            case .iphone:
                if !iphoneFiles.contains(bundleName) { iphoneFiles.append(bundleName) }
            case .ipad:
                if !ipadFiles.contains(bundleName) { ipadFiles.append(bundleName) }
            default:
                break
            }
        }

        var bundleIcons: [String: any Sendable] = [
            "CFBundleIconName": appIcon.name,
        ]
        if !iphoneFiles.isEmpty {
            bundleIcons["CFBundlePrimaryIcon"] = [
                "CFBundleIconName": appIcon.name,
                "CFBundleIconFiles": iphoneFiles,
            ] as [String: any Sendable]
        }

        var additions: [String: any Sendable] = [
            "CFBundleIcons": bundleIcons,
            "CFBundleIconName": appIcon.name,
        ]

        if !ipadFiles.isEmpty {
            additions["CFBundleIcons~ipad"] = [
                "CFBundleIconName": appIcon.name,
                "CFBundlePrimaryIcon": [
                    "CFBundleIconName": appIcon.name,
                    "CFBundleIconFiles": ipadFiles,
                ] as [String: any Sendable],
            ] as [String: any Sendable]
        }

        let fallback = Array(Set(iphoneFiles + ipadFiles)).sorted()
        if !fallback.isEmpty {
            additions["CFBundleIconFiles"] = fallback
        }

        return AppIconPlistResult(
            infoPlistAdditions: additions,
            iconName: appIcon.name,
            iconFiles: allFiles
        )
    }

    private static func formatSize(_ n: Double) -> String {
        let rounded = n.rounded()
        if abs(n - rounded) < 0.001 {
            return String(format: "%.0f", n)
        }
        return String(format: "%g", n)
    }
}
