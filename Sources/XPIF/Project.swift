// Adapted from SwiftBuild/Project.swift: mutable Xcode PIF support and lossless JSON fields.

import Foundation

extension XPIF {
    /// A PIF project, consisting of a tree of groups and file references, a list of targets, and some additional information.
    public struct Project: Sendable, Hashable {
        public let id: GUID
        public var name: String
        public var developmentRegion: String?
        public var path: String
        public var mainGroup: Group
        public var buildConfigs: [BuildConfig]
        public var projectDir: String
        public var targets: [BaseTarget]
        /// Object order can differ from the order of target references in a project.
        public var targetSerializationOrder: [GUID]? = nil
        public var isPackage: Bool
        public var defaultConfigurationName: String = "Release"
        public var knownRegions: [String]? = nil
        public var classPrefix: String? = nil
        public var appPreferencesBuildSettings: BuildSettings? = nil
        public var additionalFields: [String: JSONValue] = [:]

        public init(
            id: GUID,
            path: String,
            projectDir: String,
            name: String,
            mainGroup: Group? = nil,
            buildConfigs: [BuildConfig] = [],
            targets: [BaseTarget] = [],
            developmentRegion: String? = nil,
            isPackage: Bool = false
        ) {
            precondition(!id.value.isEmpty)
            precondition(!path.isEmpty)
            precondition(!projectDir.isEmpty)
            self.id = id
            self.name = name
            self.developmentRegion = developmentRegion
            self.path = path
            self.mainGroup = mainGroup ?? Group(id: .init("\(id.value)::MAINGROUP"), path: "")
            self.buildConfigs = buildConfigs
            self.projectDir = projectDir
            self.targets = targets
            self.isPackage = isPackage
        }

        private var nextTargetId: GUID {
            return "\(self.id.value)::TARGET_\(targets.count)"
        }

        // MARK: - Test
        public mutating func withKeyPath<T, U>(_ kp: WritableKeyPath<Project, T>, _ fn: (inout T) -> WritableKeyPath<T, U>) -> WritableKeyPath<Project, U> {
            let subkp = fn(&self[keyPath: kp])
            return kp.appending(path: subkp)
        }

        // MARK: - BuildConfig

        /// Creates and adds a new empty build configuration, i.e. one that does not initially have any build settings.  The name must not be empty and must not be equal to the name of any existing build configuration in the project.
        @discardableResult public mutating func addBuildConfig(_ create: CreateFn<BuildConfig>) -> Tag<BuildConfig> {
            let id = GUID("\(self.id.value)::BUILDCONFIG_\(buildConfigs.count)")
            let buildConfig = create(id)
            buildConfigs.append(buildConfig)
            return .init(value: buildConfig.id)
        }

        public subscript(buildConfig tag: Tag<BuildConfig>) -> BuildConfig {
            get { buildConfigs[id: tag.value] }
            set { buildConfigs[id: tag.value] = newValue }
        }

        // MARK: - BaseTarget

        /// Creates and adds a new empty target, i.e. one that does not initially have any build phases.
        /// The Target ID must be non-empty and unique within the PIF workspace; an arbitrary
        /// guaranteed-to-be-unique identifier is passed in but the user may ignore it and use a
        /// different one, as long as it adheres to the rules.  The name must not be empty and must not
        /// be equal to the name of any existing target in the project.
        @discardableResult public mutating func addTarget(_ create: CreateFn<Target>) throws -> WritableKeyPath<Project, Target> {
            let target = create(nextTargetId)
            guard !target.name.isEmpty else {
                throw Error.emptyTargetName(targetIdentifier: target.id, productName: target.productName)
            }
            guard !target.id.value.isEmpty else {
                throw Error.emptyTargetIdentifier(targetName: target.name, productName: target.productName)
            }
            guard !targets.contains(where: { $0.common.id == target.id }) else {
                throw Error.duplicatedTargetIdentifier(targetIdentifier: target.id, targetName: target.name, productName: target.productName)
            }
            targets.append(.target(target))
            return \.[target: .init(value: target.id)]
        }

        /// Adds a new aggregate target returned by the `create` closure.
        /// The Target ID must be non-empty and unique within the PIF workspace; an arbitrary
        /// guaranteed-to-be-unique identifier is passed in but the user may ignore it and use a
        /// different one, as long as it adheres to the rules.  The name must not be empty and must not
        /// be equal to the name of any existing target in the project.
        @discardableResult public mutating func addAggregateTarget(_ create: CreateFn<AggregateTarget>) throws -> WritableKeyPath<Project, AggregateTarget> {
            let target = create(nextTargetId)
            guard !target.name.isEmpty else {
                throw Error.emptyTargetName(targetIdentifier: target.id, productName: "")
            }
            guard !target.id.value.isEmpty else {
                throw Error.emptyTargetIdentifier(targetName: target.name, productName: "")
            }
            guard !targets.contains(where: { $0.common.id == target.id }) else {
                throw Error.duplicatedTargetIdentifier(targetIdentifier: target.id, targetName: target.name, productName: "")
            }
            targets.append(.aggregate(target))
            let tag = Tag<AggregateTarget>(value: target.id)
            return \.[target: tag]
        }

        public subscript(target tag: Tag<Target>) -> Target {
            get {
                guard case let .target(t) = targets[id: tag.value] else { fatalError() }
                return t
            }
            set { targets[id: tag.value] = .target(newValue) }
        }

        public subscript(target tag: Tag<AggregateTarget>) -> AggregateTarget {
            get {
                guard case let .aggregate(t) = targets[id: tag.value] else { fatalError() }
                return t
            }
            set { targets[id: tag.value] = .aggregate(newValue) }
        }

        public subscript(baseTarget tag: Tag<AggregateTarget>) -> BaseTarget {
            get { targets[id: tag.value] }
            set { targets[id: tag.value] = newValue }
        }

        public subscript(baseTarget tag: Tag<Target>) -> BaseTarget {
            get { targets[id: tag.value] }
            set { targets[id: tag.value] = newValue }
        }

        public subscript(baseTarget keyPath: WritableKeyPath<Project, AggregateTarget>) -> BaseTarget {
            get { .aggregate(self[keyPath: keyPath]) }
            set {
                switch newValue {
                case .aggregate(let target): self[keyPath: keyPath] = target
                default: break
                }
            }
        }

        public subscript(baseTarget keyPath: WritableKeyPath<Project, Target>) -> BaseTarget {
            get { .target(self[keyPath: keyPath]) }
            set {
                switch newValue {
                case .target(let target): self[keyPath: keyPath] = target
                default: break
                }
            }
        }

        public func findTarget(id: GUID) -> WritableKeyPath<Project, Target>? {
            guard targets.contains(where: { if case .target(let target) = $0 { return target.id == id }; return false }) else {
                return nil
            }
            return \.[target: .init(value: id)]
        }
    }

}


extension XPIF.Project: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(XPIF.GUID.self, forKey: .guid)
        self.name = try container.decodeIfPresent(String.self, forKey: .projectName)
            ?? URL(fileURLWithPath: container.decode(String.self, forKey: .path)).deletingPathExtension().lastPathComponent
        self.isPackage = try container.decodePIFBool(forKey: .projectIsPackage)
        self.path = try container.decode(String.self, forKey: .path)
        self.projectDir = try container.decode(String.self, forKey: .projectDirectory)
        self.buildConfigs = try container.decode([XPIF.BuildConfig].self, forKey: .buildConfigurations)
        self.mainGroup = try container.decode(XPIF.Group.self, forKey: .groupTree)
        let signatures = try container.decode([String].self, forKey: .targets)
        self.targets = signatures.compactMap { signature in
            guard let key = CodingUserInfoKey(rawValue: signature) else {
                return nil
            }
            return decoder.userInfo[key] as? XPIF.BaseTarget
        }
        self.developmentRegion = try container.decodeIfPresent(String.self, forKey: .developmentRegion)
        self.defaultConfigurationName = try container.decodeIfPresent(String.self, forKey: .defaultConfigurationName) ?? "Release"
        self.knownRegions = try container.decodeIfPresent([String].self, forKey: .knownRegions)
        self.classPrefix = try container.decodeIfPresent(String.self, forKey: .classPrefix)
        self.appPreferencesBuildSettings = try container.decodeIfPresent(XPIF.BuildSettings.self, forKey: .appPreferencesBuildSettings)
        self.additionalFields = try decodeAdditionalFields(from: decoder, excluding: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeAdditionalFields(self.additionalFields, to: encoder, excluding: CodingKeys.self)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .guid)
        if name != URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent {
            try container.encode(name, forKey: .projectName)
        }
        if isPackage { try container.encode("true", forKey: .projectIsPackage) }
        try container.encode(path, forKey: .path)
        try container.encode(projectDir, forKey: .projectDirectory)
        try container.encode(buildConfigs, forKey: .buildConfigurations)
        try container.encode(defaultConfigurationName, forKey: .defaultConfigurationName)
        try container.encode(mainGroup, forKey: .groupTree)
        try container.encode(targets.compactMap { $0.common.signature }, forKey: .targets)
        try container.encodeIfPresent(developmentRegion, forKey: .developmentRegion)
        try container.encodeIfPresent(knownRegions, forKey: .knownRegions)
        try container.encodeIfPresent(classPrefix, forKey: .classPrefix)
        try container.encodeIfPresent(appPreferencesBuildSettings, forKey: .appPreferencesBuildSettings)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case guid
        case projectDirectory
        case projectName
        case projectIsPackage
        case path
        case buildConfigurations
        case targets
        case groupTree
        case defaultConfigurationName
        case developmentRegion
        case knownRegions
        case classPrefix
        case appPreferencesBuildSettings
    }
}
