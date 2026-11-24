import XcodeProjects
import XPIF

extension XcodePIFProjectBuilder {
    static func platformFilters(_ filters: Set<XCSchema.PlatformFilter>) -> Set<XPIF.PlatformFilter> {
        Set(filters.map { filter in
            switch filter.rawValue {
            case "maccatalyst": .init(platform: "ios", environment: "maccatalyst")
            case "macos": .init(platform: "macos")
            default: .init(platform: filter.rawValue)
            }
        })
    }

    static func buildFile(
        id: XPIF.GUID, ref: XPIF.BuildFile.Ref, properties: XCSchema.BuildFileProperties
    ) -> XPIF.BuildFile {
        let attributes = properties.attributes
        var file = XPIF.BuildFile(
            id: id, ref: ref,
            headerVisibility: attributes.headerRole.flatMap { .init(rawValue: $0.rawValue) },
            generatedCodeVisibility: attributes.codeGeneration == .skip ? .noCodegen
                : attributes.codeGenerationVisibility.flatMap { .init(rawValue: $0.rawValue) },
            platformFilters: platformFilters(properties.platformFilters),
            codeSignOnCopy: attributes.codeSignOnCopy,
            removeHeadersOnCopy: attributes.headerPreservation == .removeOnCopy
        )
        file.additionalCompilerOptions = properties.additionalBuildFlags.map(XPIF.StringList.string)
        file.shouldLinkWeakly = attributes.isWeak
        file.decompress = attributes.decompress
        file.assetTags = Set(properties.assetTags.map(\.rawValue))
        file.migCodegenFiles = attributes.machInterfaceGeneration?.rawValue
        return file
    }
}
