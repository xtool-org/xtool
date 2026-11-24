// Adapted from swift-package-manager/SwiftBuildSupport/PIF.swift: mutable Xcode PIF support and lossless JSON fields.

import Foundation
import Crypto
import OrderedCollections

extension XPIF {
    public struct Container: Sendable {
        public var workspace: Workspace

        public init(workspace: Workspace) {
            self.workspace = workspace
        }

        /// The high-level PIF *workspace* object.
        public struct Workspace: HighLevelObject {
            fileprivate static var type: String { "workspace" }

            public let id: XPIF.GUID
            public var name: String
            public var path: String
            public var additionalFields: [String: JSONValue] = [:]
            public var projects: [XPIF.Project] {
                get { projectsWithSignature.map(\.underlying) }
                set { projectsWithSignature = newValue.map { Container.Project(wrapping: $0) } }
            }

            fileprivate var projectsWithSignature: [Container.Project]
            fileprivate var projectSignatures: [String]
            fileprivate var signature: String?

            public init(id: XPIF.GUID, name: String, path: String, projects: [XPIF.Project]) {
                precondition(!id.value.isEmpty)
                precondition(!name.isEmpty)
                precondition(Set(projects.map(\.id)).count == projects.count)

                self.id = id
                self.name = name
                self.path = path

                self.projectsWithSignature = []
                self.projectSignatures = []
                self.projects = projects
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: Container.CodingKeys.self)
                try Self.validateType(in: container)
                signature = try container.decode(String.self, forKey: .signature)

                let contents = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .contents)
                id = try contents.decode(XPIF.GUID.self, forKey: .guid)
                name = try contents.decode(String.self, forKey: .name)
                path = try contents.decode(String.self, forKey: .path)
                projectSignatures = try contents.decode([String].self, forKey: .projects)
                projectsWithSignature = []
                additionalFields = try decodeAdditionalFields(from: container.superDecoder(forKey: .contents), excluding: CodingKeys.self)
            }

            private enum CodingKeys: String, CodingKey, CaseIterable {
                case guid, name, path, projects
            }

            fileprivate mutating func sign() throws {
                for projectIndex in projects.indices {
                    try projectsWithSignature[projectIndex].sign()
                }
                self.signature = try Container.signature(of: self)
            }

            fileprivate func encodeContents(to encoder: Encoder) throws {
                var superContainer = encoder.container(keyedBy: Container.CodingKeys.self)
                let contentsEncoder = superContainer.superEncoder(forKey: .contents)
                try encodeAdditionalFields(additionalFields, to: contentsEncoder, excluding: CodingKeys.self)
                var contents = contentsEncoder.container(keyedBy: CodingKeys.self)

                try contents.encode(id, forKey: .guid)
                try contents.encode(name, forKey: .name)
                try contents.encode(path, forKey: .path)
                try contents.encode(projectsWithSignature.map(\.signature), forKey: .projects)

                if encoder.userInfo.keys.contains(.encodeForSwiftBuild) {
                    guard let signature else {
                        throw Errors.missingSignature(type: Self.type)
                    }
                    try superContainer.encode(signature, forKey: .signature)
                }
            }
        }

        /// Decodes a `Container` from PIF JSON.
        public init(data: Data) throws {
            let objects = try JSONDecoder().decode([TopLevelObject.Entry].self, from: data)
            var workspace: Workspace?
            var projects: [String: Project] = [:]
            var targets: OrderedDictionary<String, XPIF.BaseTarget> = [:]

            for object in objects {
                switch object {
                case .workspace(let value):
                    guard workspace == nil else {
                        throw Self.invalidPIF("PIF contains more than one workspace")
                    }
                    workspace = value
                case .project(let value):
                    guard let signature = value.signature, projects[signature] == nil else {
                        throw Self.invalidPIF("PIF contains a project with a missing or duplicate signature")
                    }
                    projects[signature] = value
                case .target(let value):
                    guard let signature = value.underlying.common.signature, targets[signature] == nil else {
                        throw Self.invalidPIF("PIF contains a target with a missing or duplicate signature")
                    }
                    targets[signature] = value.underlying
                }
            }

            guard var workspace else {
                throw Self.invalidPIF("PIF is missing a workspace")
            }
            workspace.projectsWithSignature = try workspace.projectSignatures.map { signature in
                guard var project = projects[signature] else {
                    throw Self.invalidPIF("PIF is missing project with signature \(signature)")
                }
                project.underlying.targets = try project.targetSignatures.map { signature in
                    guard let target = targets[signature] else {
                        throw Self.invalidPIF("PIF is missing target with signature \(signature)")
                    }
                    return target
                }
                let projectSignatures = Set(project.targetSignatures)
                let serializedIDs = targets.filter { projectSignatures.contains($0.key) }.values.map(\.id)
                if serializedIDs != project.underlying.targets.map(\.id) {
                    project.underlying.targetSerializationOrder = serializedIDs
                }
                return project
            }
            self.workspace = workspace
        }

        private static func invalidPIF(_ description: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: [], debugDescription: description))
        }

        /// Encodes the receiver as PIF JSON data.
        public func data() throws -> Data {
            var workspace = workspace
            try workspace.sign()
            let topLevel = TopLevelObject(workspace: workspace)
            return try Self.swiftBuildEncoder.encode(topLevel)
        }

        public enum Errors: Swift.Error, CustomStringConvertible {
            case missingSignature(type: String)

            public var description: String {
                switch self {
                case .missingSignature(let type):
                    return "Expected to have \(type) *signature* when encoding for SwiftBuild"
                }
            }
        }

        fileprivate static func makeEncoder(forSwiftBuild: Bool) -> JSONEncoder {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if forSwiftBuild {
                encoder.userInfo[.encodeForSwiftBuild] = true
            }
            return encoder
        }
        fileprivate static let swiftBuildEncoder = makeEncoder(forSwiftBuild: true)
        fileprivate static let standardEncoder = makeEncoder(forSwiftBuild: false)

        /// The top-level PIF object.
        fileprivate struct TopLevelObject: Encodable {
            let workspace: Workspace

            enum Entry: Decodable {
                case workspace(Workspace)
                case project(Project)
                case target(Target)

                init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: Container.CodingKeys.self)
                    switch try container.decode(String.self, forKey: .type) {
                    case "workspace": self = .workspace(try Workspace(from: decoder))
                    case "project": self = .project(try Project(from: decoder))
                    case "target": self = .target(try Target(from: decoder))
                    default:
                        throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown PIF object type")
                    }
                }
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.unkeyedContainer()

                // Encode the workspace.
                try container.encode(workspace)

                // Encode the projects and their targets.
                for project in workspace.projectsWithSignature {
                    try container.encode(project)

                    var targets = project.underlying.targets
                    if let order = project.underlying.targetSerializationOrder {
                        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
                        targets.sort { ranks[$0.id, default: .max] < ranks[$1.id, default: .max] }
                    }
                    for target in targets {
                        try container.encode(Target(wrapping: target))
                    }
                }
            }
        }

        fileprivate enum CodingKeys: CodingKey {
            case type
            case signature, contents // Used by subclasses.
        }

        /// Represents a high-level PIF object.
        ///
        /// For instance, a JSON serialized *workspace* might look like this:
        /// ```json
        /// {
        ///     "type" : "workspace",
        ///     "signature" : "22e9436958aec481799",
        ///     "contents" : {
        ///         "guid" : "Workspace:/Users/foo/BarPackage",
        ///         "name" : "BarPackage",
        ///         "path" : "/Users/foo/BarPackage",
        ///         "projects" : [
        ///             "70a588f37dcfcddbc1f",
        ///             "c1d9cb257bd42cafbb8"
        ///         ]
        ///     }
        /// }
        /// ```
        fileprivate protocol HighLevelObject: Codable, Sendable {
            static var type: String { get }
            func encodeContents(to encoder: Encoder) throws
        }

        /// A high-level PIF *project* object.
        fileprivate struct Project: HighLevelObject {
            static var type: String { "project" }

            var underlying: XPIF.Project
            var signature: String?
            var targetSignatures: [String] = []
            var id: XPIF.GUID { underlying.id }

            init(wrapping underlying: XPIF.Project) {
                precondition(!underlying.name.isEmpty)
                precondition(!underlying.id.value.isEmpty)
                precondition(!underlying.path.isEmpty)
                precondition(!underlying.projectDir.isEmpty)

                precondition(Set(underlying.targets.map(\.id)).count == underlying.targets.count)
                precondition(Set(underlying.buildConfigs.map(\.id)).count == underlying.buildConfigs.count)

                self.underlying = underlying
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: Container.CodingKeys.self)
                try Self.validateType(in: container)
                signature = try container.decode(String.self, forKey: .signature)
                let contents = try container.nestedContainer(keyedBy: TargetCodingKeys.self, forKey: .contents)
                targetSignatures = try contents.decode([String].self, forKey: .targets)
                underlying = try container.decode(XPIF.Project.self, forKey: .contents)
            }

            private enum TargetCodingKeys: CodingKey {
                case targets
            }

            mutating func sign() throws {
                for targetIndex in self.underlying.targets.indices {
                    try self.underlying.targets[targetIndex].sign()
                }
                self.signature = try Container.signature(of: self)
            }

            func encodeContents(to encoder: any Encoder) throws {
                var superContainer = encoder.container(keyedBy: CodingKeys.self)
                try superContainer.encode(underlying, forKey: .contents)

                if encoder.userInfo.keys.contains(.encodeForSwiftBuild) {
                    guard let signature else {
                        throw Container.Errors.missingSignature(type: Self.type)
                    }
                    try superContainer.encode(signature, forKey: .signature)
                }
            }
        }

        /// A high-level PIF *target* object.
        fileprivate struct Target: HighLevelObject {
            static var type: String { "target" }

            var underlying: XPIF.BaseTarget
            var id: XPIF.GUID { underlying.id }

            init(wrapping underlying: XPIF.BaseTarget) {
                precondition(!underlying.id.value.isEmpty)
                precondition(!underlying.common.name.isEmpty)

                self.underlying = underlying
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: Container.CodingKeys.self)
                try Self.validateType(in: container)
                let signature = try container.decode(String.self, forKey: .signature)
                underlying = try container.decode(XPIF.BaseTarget.self, forKey: .contents)
                underlying.common.signature = signature
            }

            func encodeContents(to encoder: any Encoder) throws {
                var superContainer = encoder.container(keyedBy: Container.CodingKeys.self)
                try superContainer.encode(underlying, forKey: .contents)

                if encoder.userInfo.keys.contains(.encodeForSwiftBuild) {
                    guard let signature = underlying.common.signature else {
                        throw Container.Errors.missingSignature(type: Self.type)
                    }
                    try superContainer.encode(signature, forKey: .signature)
                }
            }
        }

        fileprivate static func signature(of obj: some Encodable) throws -> String {
            let signatureContent = try standardEncoder.encode(obj)
            return SHA256.hash(data: signatureContent)
                .map { String(format: "%02X", $0) }
                .joined()
        }
    }
}

extension XPIF.BaseTarget {
    fileprivate mutating func sign() throws {
        self.common.signature = try XPIF.Container.signature(of: self)
    }
}

extension CodingUserInfoKey {
    /// Perform the encoding for SwiftBuild consumption.
    fileprivate static let encodeForSwiftBuild: CodingUserInfoKey = CodingUserInfoKey(rawValue: "encodeForXCBuild")!
}

extension XPIF.Container.HighLevelObject {
    fileprivate static func validateType(in container: KeyedDecodingContainer<XPIF.Container.CodingKeys>) throws {
        let expected = Self.type
        let type = try container.decode(String.self, forKey: .type)
        guard type == expected else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected \(expected), got \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: XPIF.Container.CodingKeys.self)
        try container.encode(Self.type, forKey: .type)
        try self.encodeContents(to: encoder)
    }
}

extension XPIF {
    public typealias Workspace = Container.Workspace
}
