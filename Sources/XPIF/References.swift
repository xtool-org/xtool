// Adapted from SwiftBuild/References.swift: mutable Xcode PIF support and lossless JSON fields.

import Foundation

extension XPIF {
    // MARK: - References

    /// Base enum for all items in the group hierarchy.
    public enum Reference: Sendable, Hashable {
        /// Determines the base path for a reference's relative path.
        public enum RefPathBase: Sendable, Hashable, Codable {
            case absolute
            case groupDir
            case buildSetting(String)

            public static let projectDir = Self.buildSetting("SOURCE_ROOT")
            public static let buildDir = Self.buildSetting("BUILT_PRODUCTS_DIR")

            public var asString: String {
                switch self {
                case .absolute: "<absolute>"
                case .groupDir: "<group>"
                case .buildSetting(let name): name
                }
            }

            public init(from decoder: any Decoder) throws {
                let value = try decoder.singleValueContainer().decode(String.self)
                switch value {
                case "<absolute>": self = .absolute
                case "<group>": self = .groupDir
                default: self = .buildSetting(value)
                }
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(asString)
            }
        }

        case file(FileReference)
        case group(Group)

        public var id: GUID {
            switch self {
            case let .file(fref): return fref.id
            case let .group(group): return group.common.id
            }
        }
    }

    public struct ReferenceCommon: Sendable, Hashable {
        public let id: GUID
        public var additionalFields: [String: JSONValue] = [:]
        var explicitDefaults: [String: JSONValue] = [:]

        /// Relative path of the reference.  It is usually a literal, but may in fact contain build settings.
        public var path: String

        /// Determines the base path for the reference's relative path.
        public var pathBase: Reference.RefPathBase

        /// Name of the reference.
        public var name: String

        init(id: GUID, path: String, pathBase: Reference.RefPathBase, name: String) {
            self.id = id
            self.path = path
            self.pathBase = pathBase
            self.name = name
        }
    }

    /// A reference to a file system entity (a file, folder, etc).
    public struct FileReference: Common, Sendable, Hashable {
        public var common: ReferenceCommon
        public var fileType: String
        public var regionVariantName: String? = nil
        public var fileTextEncoding: String? = nil
        public var expectedSignature: String? = nil

        public init(id: GUID, path: String, pathBase: Reference.RefPathBase = .groupDir, name: String? = nil, fileType: String? = nil) {
            self.common = ReferenceCommon(id: id, path: path, pathBase: pathBase, name: name ?? path)
            self.fileType = fileType ?? Self.fileTypeIdentifier(for: path)
        }
    }

    /// A group that can contain References (FileReferences and other Groups).  The resolved path of a group is used as the base path for any child references whose source tree type is GroupRelative.
    public struct Group: Common, Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable, Codable {
            case group
            case variantGroup
            case versionGroup
        }

        public var kind: Kind = .group
        public var common: ReferenceCommon
        public var subitems: [Reference] = []

        public init(id: GUID, path: String, pathBase: Reference.RefPathBase = .groupDir, name: String? = nil, subitems: [Reference] = []) {
            self.common = ReferenceCommon(id: id, path: path, pathBase: pathBase, name: name ?? path)
            self.subitems = subitems
        }

        private var nextRefId: GUID {
            return "\(self.common.id.value)::REF_\(subitems.count)"
        }

        // MARK: - Reference subitems

        /// Creates and appends a new FileReference to the list of subitems.
        @discardableResult public mutating func addFileReference(_ create: CreateFn<FileReference>) -> FileReference {
            let fref = create(nextRefId)
            subitems.append(.file(fref))
            return fref
        }

        @discardableResult public mutating func addGroup(_ create: CreateFn<Group>) -> WritableKeyPath<Group, Group> {
            let group = create(nextRefId)
            subitems.append(.group(group))
            let tag = Tag<Group>(value: group.id)
            return \.[group: tag]
        }

        fileprivate subscript(group tag: Tag<Group>) -> Group {
            get {
                guard case let .group(t) = subitems.first(where: { $0.id == tag.value }) else { fatalError() }
                return t
            }
            set {
                guard let idx = subitems.firstIndex(where: { $0.id == tag.value }) else { fatalError() }
                subitems[idx] = .group(newValue)
            }
        }
    }


}


extension XPIF.Reference: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "file":
            self = .file(try .init(from: decoder))
        case "group", "variantGroup", "versionGroup":
            self = .group(try .init(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown value for key")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .file(fref):
            try fref.encode(to: encoder)
        case let .group(group):
            try group.encode(to: encoder)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
    }
}

extension XPIF.FileReference: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(XPIF.GUID.self, forKey: .guid)
        let pathBase = try container.decodeIfPresent(XPIF.Reference.RefPathBase.self, forKey: .sourceTree) ?? .groupDir
        let path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        let name = try container.decodeIfPresent(String.self, forKey: .name) ?? (path as NSString).lastPathComponent
        self.common = .init(id: id, path: path, pathBase: pathBase, name: name)
        self.fileType = try container.decodeIfPresent(String.self, forKey: .fileType) ?? Self.fileTypeIdentifier(for: path)
        self.regionVariantName = try container.decodeIfPresent(String.self, forKey: .regionVariantName)
        self.fileTextEncoding = try container.decodeIfPresent(String.self, forKey: .fileTextEncoding)
        self.expectedSignature = try container.decodeIfPresent(String.self, forKey: .expectedSignature)
        self.common.additionalFields = try decodeAdditionalFields(from: decoder, excluding: CodingKeys.self)
        self.common.explicitDefaults = try decodeExplicitDefaults(from: decoder, defaults: ["name": .string((path as NSString).lastPathComponent)])
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeExplicitDefaults(common.explicitDefaults, to: encoder)
        try encodeAdditionalFields(self.common.additionalFields, to: encoder, excluding: CodingKeys.self)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("file", forKey: .type)
        try container.encode(self.id, forKey: .guid)
        if common.explicitDefaults["name"] != nil || self.name != (self.path as NSString).lastPathComponent {
            try container.encode(self.name, forKey: .name)
        }
        try container.encode(self.pathBase, forKey: .sourceTree)
        try container.encode(self.path, forKey: .path)
        try container.encode(self.fileType, forKey: .fileType)
        try container.encodeIfPresent(regionVariantName, forKey: .regionVariantName)
        try container.encodeIfPresent(fileTextEncoding, forKey: .fileTextEncoding)
        try container.encodeIfPresent(expectedSignature, forKey: .expectedSignature)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case type
        case guid
        case sourceTree
        case path
        case fileType
        case regionVariantName, fileTextEncoding, expectedSignature
        case name
    }

    private static func fileTypeIdentifier(for path: String) -> String {
        // FIXME: We need real logic here.  <rdar://problem/33634352> [SwiftPM] When generating PIF, we need a standard way to determine the file type
        let pathExtension = (path as NSString).pathExtension as String
        switch pathExtension {
        case "txt": return "text"
        case "xcodeproj": return "wrapper.pb-project"
        case "xcconfig": return "text.xcconfig"
        case "plist": return "text.plist.xml"
        case "strings": return "text.plist.strings"
        case "h": return "sourcecode.c.h"
        case "framework": return "wrapper.framework"
        case "app": return "wrapper.application"
        case "xcdatamodeld": return "wrapper.xcdatamodeld"
        case "xcdatamodel": return "wrapper.xcdatamodel"
        case "xcmappingmodel": return "wrapper.xcmappingmodel"
        case "mlmodel": return "file.mlmodel"
        case "mlpackage": return "folder.mlpackage"
        case "referenceobject": return "file.referenceobject"
        case "a":
            return "archive.ar"
        case "s", "S":
            return "sourcecode.asm"
        case "c":
            return "sourcecode.c.c"
        case "cl":
            return "sourcecode.opencl"
        case "cpp", "cp", "cxx", "cc", "c++", "C", "tcc":
            return "sourcecode.cpp.cpp"
        case "d":
            return "sourcecode.dtrace"
        case "defs", "mig":
            return "sourcecode.mig"
        case "m":
            return "sourcecode.c.objc"
        case "mm", "M":
            return "sourcecode.cpp.objcpp"
        case "metal":
            return "sourcecode.metal"
        case "l", "lm", "lmm", "lpp", "lp", "lxx":
            return "sourcecode.lex"
        case "swift":
            return "sourcecode.swift"
        case "y", "ym", "ymm", "ypp", "yp", "yxx":
            return "sourcecode.yacc"


        // FIXME: This is probably now more important because of resources support.
        case "xcassets":
            return "folder.assetcatalog"
        case "icon":
            return "folder.iconcomposer.icon"
        case "xcstrings":
            return "text.json.xcstrings"
        case "storyboard":
            return "file.storyboard"
        case "xib":
            return "file.xib"

        case "xcframework":
            return "wrapper.xcframework"
        case "artifactbundle":
            return "wrapper.artifactbundle"

        case "docc":
            return "folder.documentationcatalog"

        case "rkassets":
            return "folder.rkassets"

        default:
            return "file"
        }
    }

}

extension XPIF.Group: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(XPIF.GUID.self, forKey: .guid)
        let pathBase = try container.decodeIfPresent(XPIF.Reference.RefPathBase.self, forKey: .sourceTree) ?? .groupDir
        let path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        let name = try container.decodeIfPresent(String.self, forKey: .name) ?? path
        self.common = .init(id: id, path: path, pathBase: pathBase, name: name)
        self.subitems = try container.decodeIfPresent([XPIF.Reference].self, forKey: .children) ?? []
        self.kind = try container.decodeIfPresent(Kind.self, forKey: .type) ?? .group
        self.common.additionalFields = try decodeAdditionalFields(from: decoder, excluding: CodingKeys.self)
        self.common.explicitDefaults = try decodeExplicitDefaults(from: decoder, defaults: ["children": .array([])])
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeExplicitDefaults(common.explicitDefaults, to: encoder)
        try encodeAdditionalFields(self.common.additionalFields, to: encoder, excluding: CodingKeys.self)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        try container.encode(self.id, forKey: .guid)
        try container.encode(self.pathBase, forKey: .sourceTree)
        try container.encode(self.path, forKey: .path)
        try container.encode(self.name, forKey: .name)
        if !subitems.isEmpty { try container.encode(subitems, forKey: .children) }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case type
        case guid
        case sourceTree
        case path
        case name
        case children
    }

}
