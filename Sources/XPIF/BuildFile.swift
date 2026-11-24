// Adapted from SwiftBuild/BuildFile.swift: mutable Xcode PIF support and lossless JSON fields.

import Foundation

extension XPIF {
    /// A build file, representing the membership of either a file or target product reference in a build phase.
    public struct BuildFile: Sendable, Hashable, Identifiable {
        public var additionalFields: [String: JSONValue] = [:]
        var explicitDefaults: [String: JSONValue] = [:]
        public enum Ref: Sendable, Hashable {
            case reference(id: GUID)
            case targetProduct(id: GUID)
            case namedReference(name: String, fileType: String)
        }
        public enum HeaderVisibility: String, Sendable, Hashable, Codable {
            case `public` = "public"
            case `private` = "private"
        }
        public enum GeneratedCodeVisibility: String, Sendable, Hashable, Codable {
            case `public`
            case `private`
            case project
            case noCodegen = "no_codegen"
        }
        public enum ResourceRule: String, Sendable, Hashable, Codable {
            case process
            case copy
            case embedInCode
        }

        public let id: GUID
        public var ref: Ref
        public var headerVisibility: HeaderVisibility? = nil
        public var generatedCodeVisibility: GeneratedCodeVisibility? = nil
        public var platformFilters: Set<PlatformFilter> = []
        public var codeSignOnCopy: Bool = false
        public var removeHeadersOnCopy: Bool = false
        public var resourceRule: ResourceRule? = nil
        public var additionalCompilerOptions: StringList? = nil
        public var shouldLinkWeakly: Bool = false
        public var assetTags: Set<String> = []
        public var decompress: Bool = false
        public var shouldWarnIfNoRuleToProcess: Bool = true
        public var migCodegenFiles: String? = nil

        public init(
            id: GUID,
            ref: Ref,
            headerVisibility: HeaderVisibility? = nil,
            generatedCodeVisibility: GeneratedCodeVisibility? = nil,
            platformFilters: Set<PlatformFilter> = [],
            codeSignOnCopy: Bool = false,
            removeHeadersOnCopy: Bool = false,
            resourceRule: ResourceRule? = nil
        ) {
            self.id = id
            self.ref = ref
            self.headerVisibility = headerVisibility
            self.generatedCodeVisibility = generatedCodeVisibility
            self.platformFilters = platformFilters
            self.codeSignOnCopy = codeSignOnCopy
            self.removeHeadersOnCopy = removeHeadersOnCopy
            self.resourceRule = resourceRule
        }

        public init(
            id: GUID,
            fileRef: FileReference,
            headerVisibility: HeaderVisibility? = nil,
            generatedCodeVisibility: GeneratedCodeVisibility? = nil,
            platformFilters: Set<PlatformFilter> = [],
            codeSignOnCopy: Bool = false,
            removeHeadersOnCopy: Bool = false,
            resourceRule: ResourceRule? = nil
        ) {
            self.init(id: id, ref: .reference(id: fileRef.id), headerVisibility: headerVisibility, generatedCodeVisibility: generatedCodeVisibility, platformFilters: platformFilters, codeSignOnCopy: codeSignOnCopy, removeHeadersOnCopy: removeHeadersOnCopy, resourceRule: resourceRule)
        }
    }
}


extension XPIF.BuildFile: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(XPIF.GUID.self, forKey: .guid)
        self.platformFilters = try container.decodeIfPresent(Set<XPIF.PlatformFilter>.self, forKey: .platformFilters) ?? []

        if let refId = try container.decodeIfPresent(XPIF.GUID.self, forKey: .fileReference) {
            self.ref = .reference(id: refId)
        } else if let refId = try container.decodeIfPresent(XPIF.GUID.self, forKey: .targetReference) {
            self.ref = .targetProduct(id: refId)
        } else {
            self.ref = .namedReference(
                name: try container.decode(String.self, forKey: .name),
                fileType: try container.decode(String.self, forKey: .fileType)
            )
        }
        self.headerVisibility = try container.decodeIfPresent(HeaderVisibility.self, forKey: .headerVisibility)
        self.generatedCodeVisibility = try container.decodeIfPresent(GeneratedCodeVisibility.self, forKey: .intentsCodegenVisibility)
        if generatedCodeVisibility == nil, try container.decodePIFBool(forKey: .intentsCodegenFiles) {
            generatedCodeVisibility = .public
        }
        self.resourceRule = try container.decodeIfPresent(ResourceRule.self, forKey: .resourceRule)
        self.additionalCompilerOptions = try container.decodeIfPresent(XPIF.StringList.self, forKey: .additionalCompilerOptions)
        self.codeSignOnCopy = try container.decodePIFBool(forKey: .codeSignOnCopy)
        self.removeHeadersOnCopy = try container.decodePIFBool(forKey: .removeHeadersOnCopy)
        self.shouldLinkWeakly = try container.decodePIFBool(forKey: .shouldLinkWeakly)
        self.assetTags = try container.decodeIfPresent(Set<String>.self, forKey: .assetTags) ?? []
        self.decompress = try container.decodePIFBool(forKey: .decompress)
        self.shouldWarnIfNoRuleToProcess = try container.decodePIFBool(forKey: .shouldWarnIfNoRuleToProcess, default: true)
        self.migCodegenFiles = try container.decodeIfPresent(String.self, forKey: .migCodegenFiles)

        self.additionalFields = try decodeAdditionalFields(from: decoder, excluding: CodingKeys.self)
        self.explicitDefaults = try decodeExplicitDefaults(from: decoder, defaults: ["platformFilters": .array([]), "codeSignOnCopy": .string("false"), "removeHeadersOnCopy": .string("false")])
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeExplicitDefaults(explicitDefaults, to: encoder)
        try encodeAdditionalFields(self.additionalFields, to: encoder, excluding: CodingKeys.self)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .guid)
        if !platformFilters.isEmpty { try container.encode(platformFilters.sorted(), forKey: .platformFilters) }

        switch self.ref {
        case .reference(id: let refId):
            try container.encode(refId, forKey: .fileReference)
        case .targetProduct(id: let refId):
            try container.encode(refId, forKey: .targetReference)
        case .namedReference(let name, let fileType):
            try container.encode(name, forKey: .name)
            try container.encode(fileType, forKey: .fileType)
        }
        try container.encodeIfPresent(headerVisibility, forKey: .headerVisibility)
        try container.encodeIfPresent(generatedCodeVisibility, forKey: .intentsCodegenVisibility)
        try container.encodeIfPresent(resourceRule, forKey: .resourceRule)
        try container.encodeIfPresent(additionalCompilerOptions, forKey: .additionalCompilerOptions)
        if codeSignOnCopy { try container.encode("true", forKey: .codeSignOnCopy) }
        if removeHeadersOnCopy { try container.encode("true", forKey: .removeHeadersOnCopy) }
        if shouldLinkWeakly { try container.encode("true", forKey: .shouldLinkWeakly) }
        if !assetTags.isEmpty { try container.encode(assetTags.sorted(), forKey: .assetTags) }
        if decompress { try container.encode("true", forKey: .decompress) }
        if !shouldWarnIfNoRuleToProcess { try container.encode("false", forKey: .shouldWarnIfNoRuleToProcess) }
        try container.encodeIfPresent(migCodegenFiles, forKey: .migCodegenFiles)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case guid
        case fileReference
        case headerVisibility
        case platformFilters
        case codeSignOnCopy
        case removeHeadersOnCopy
        case intentsCodegenVisibility
        case resourceRule
        case targetReference
        case name, fileType, additionalCompilerOptions, shouldLinkWeakly, assetTags
        case decompress, shouldWarnIfNoRuleToProcess, migCodegenFiles, intentsCodegenFiles
    }
}


