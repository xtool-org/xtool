import Foundation
import XUtils

public struct CompiledCatalog: Sendable {
    public struct EmittedFile: Sendable {
        /// Filename relative to the app bundle root (e.g. "AppIcon60x60@2x.png").
        public var name: String
        public var data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    public var carData: Data
    public var infoPlistAdditions: [String: any Sendable]
    public var primaryIconName: String?
    /// Loose files that must be copied into the app bundle root alongside
    /// `Assets.car`. Currently used for the appicon PNGs that match the
    /// CFBundleIconFiles entries (e.g. AppIcon60x60@2x.png, @3x.png) --
    /// SpringBoard requires these files in addition to the Assets.car
    /// rendition for SpringBoard's icon-rendering pipeline to find the icon.
    public var emittedFiles: [EmittedFile]
}

public struct XCAssetCompiler: Sendable {
    public var deploymentTarget: String
    public var diagnostics: Diagnostics

    public init(deploymentTarget: String, diagnostics: Diagnostics) {
        self.deploymentTarget = deploymentTarget
        self.diagnostics = diagnostics
    }

    public func compile(catalog catalogURL: URL) async throws -> CompiledCatalog {
        let loader = CatalogLoader(diagnostics: diagnostics)
        let loaded = try await loader.load(catalog: catalogURL)

        var renditions: [Rendition] = []

        for imageSet in loaded.imageSets {
            renditions.append(contentsOf: try ImageRenderer.renditions(for: imageSet))
        }
        for colorSet in loaded.colorSets {
            renditions.append(contentsOf: try ColorRenderer.renditions(for: colorSet))
        }

        var appIconResult: AppIconPlistResult?
        if let appIcon = loaded.appIcon {
            let result = try AppIconPlistEmitter.emit(appIcon)
            appIconResult = result
            renditions.append(contentsOf: try ImageRenderer.appIconRenditions(for: appIcon, files: result.iconFiles))
        }

        let writer = CARWriter(deploymentTarget: deploymentTarget, renditions: renditions)
        let bytes = try writer.write()

        var additions: [String: any Sendable] = [:]
        var primaryIconName: String?
        var emittedFiles: [CompiledCatalog.EmittedFile] = []
        if let appIconResult {
            additions = appIconResult.infoPlistAdditions
            primaryIconName = appIconResult.iconName
            // Copy each appicon source PNG to the bundle root with the name
            // CFBundleIconFiles expects: "<outputName>@<scale>x.png" (or
            // "<outputName>.png" for @1x).
            for file in appIconResult.iconFiles {
                let suffix = file.scale == 1 ? "" : "@\(file.scale)x"
                let target = "\(file.outputName)\(suffix).png"
                let data = try Data(contentsOf: file.sourceURL)
                emittedFiles.append(CompiledCatalog.EmittedFile(name: target, data: data))
            }
        }

        return CompiledCatalog(
            carData: bytes,
            infoPlistAdditions: additions,
            primaryIconName: primaryIconName,
            emittedFiles: emittedFiles
        )
    }
}
