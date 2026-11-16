// Adapted from SwiftBuild/Targets.swift: mutable Xcode PIF support and lossless JSON fields.

import Foundation

extension XPIF {
    public enum BaseTarget: Identifiable, Sendable, Hashable {
        case target(Target)
        case aggregate(AggregateTarget)
        case external(ExternalTarget)

        public var id: GUID { common.id }

        public var common: TargetCommon {
            get {
                switch self {
                case let .target(target): return target.common
                case let .aggregate(target): return target.common
                case let .external(target): return target.common
                }
            }
            _modify {
                switch self {
                case var .target(target):
                    yield &target.common
                    self = .target(target)
                case var .aggregate(target):
                    yield &target.common
                    self = .aggregate(target)
                case var .external(target):
                    yield &target.common
                    self = .external(target)
                }
            }
        }
    }

    public struct TargetCommon: Sendable, Identifiable, Hashable {
        public let id: GUID
        public var signature: String? = nil
        public var name: String
        public var buildConfigs: [BuildConfig] = []
        public var buildPhases: [BuildPhase] = []
        public var buildRules: [BuildRule] = []
        public var dependencies: [TargetDependency] = []
        public var customTasks: [CustomTask] = []
        public var additionalFields: [String: JSONValue] = [:]
        var explicitDefaults: [String: JSONValue] = [:]

        // MARK: - BuildConfig

        /// Creates and adds a new empty build configuration, i.e. one that does not initially have any build settings.  The name must not be empty and must not be equal to the name of any existing build configuration in the target.
        @discardableResult public mutating func addBuildConfig(_ create: CreateFn<BuildConfig>) -> BuildConfig {
            let id = GUID("\(self.id.value)::BUILDCONFIG_\(self.buildConfigs.count)")
            let buildConfig = create(id)

            precondition(!buildConfig.name.isEmpty)
            precondition(!buildConfigs.contains{ $0.name == buildConfig.name })

            self.buildConfigs.append(buildConfig)
            return buildConfig
        }

        public subscript(buildConfig tag: Tag<BuildConfig>) -> BuildConfig {
            get { buildConfigs[id: tag.value] }
            set { buildConfigs[id: tag.value] = newValue }
        }


        // MARK: - BuildPhase
        public typealias BuildPhaseTag<Phase> = XTag<Phase, GUID>

        private var nextBuildPhaseId: GUID {
            return "\(self.id.value)::BUILDPHASE_\(buildPhases.count)"
        }

        /// Adds a "headers" build phase, i.e. one that copies headers into a directory of the product, after suitable processing.
        @discardableResult public mutating func addHeadersBuildPhase(_ create: CreateFn<HeadersBuildPhase>) -> BuildPhaseTag<HeadersBuildPhase> {
            let phase = create(nextBuildPhaseId)
            buildPhases.append(.headers(phase))
            return .init(value: phase.id)
        }

        /// Adds a "sources" build phase, i.e. one that compiles sources and provides them to be linked into the executable code of the product.
        @discardableResult public mutating func addSourcesBuildPhase(_ create: CreateFn<SourcesBuildPhase>) -> BuildPhaseTag<SourcesBuildPhase> {
            let phase = create(nextBuildPhaseId)
            buildPhases.append(.sources(phase))
            return .init(value: phase.id)
        }

        /// Adds a "frameworks" build phase, i.e. one that links compiled code and libraries into the executable of the product.
        @discardableResult public mutating func addFrameworksBuildPhase(_ create: CreateFn<FrameworksBuildPhase>) -> BuildPhaseTag<FrameworksBuildPhase> {
            let phase = create(nextBuildPhaseId)
            buildPhases.append(.frameworks(phase))
            return .init(value: phase.id)
        }

        /// Adds a "copy files" build phase, i.e. one that copies files to an arbitrary location relative to the product.
        @discardableResult public mutating func addCopyBundleResourcesBuildPhase(_ create: CreateFn<CopyBundleResourcesBuildPhase>) -> BuildPhaseTag<CopyBundleResourcesBuildPhase> {
            let phase = create(nextBuildPhaseId)
            buildPhases.append(.copyBundleResources(phase))
            return .init(value: phase.id)
        }

        @discardableResult public mutating func addCopyFilesBuildPhase(_ create: CreateFn<CopyFilesBuildPhase>) -> WritableKeyPath<TargetCommon, CopyFilesBuildPhase> {
            let phase = create(nextBuildPhaseId)
            buildPhases.append(.copyFiles(phase))
            let tag = Tag<CopyFilesBuildPhase>(value: phase.id)
            return \.[buildPhase: tag]
        }

        /// Adds a "shell script" build phase, i.e. one that runs a custom shell script as part of the build.
        @discardableResult public mutating func addShellScriptBuildPhase(insertAtFront: Bool = false, _ create: CreateFn<ShellScriptBuildPhase>) -> BuildPhaseTag<ShellScriptBuildPhase> {
            let phase = create(nextBuildPhaseId)
            if insertAtFront {
                buildPhases.insert(.shellScript(phase), at: 0)
            } else {
                buildPhases.append(.shellScript(phase))
            }
            return .init(value: phase.id)
        }

        public subscript(buildPhase tag: BuildPhaseTag<HeadersBuildPhase>) -> HeadersBuildPhase {
            get {
                guard let idx = firstPhaseIndex(tag.value),
                      case let .headers(t) = buildPhases[idx] else { fatalError() }
                return t
            }
            set {
                guard let idx = firstPhaseIndex(tag.value) else {
                    fatalError()
                }
                buildPhases[idx] = .headers(newValue)
            }
        }

        public subscript(buildPhase tag: BuildPhaseTag<SourcesBuildPhase>) -> SourcesBuildPhase {
            get {
                guard let idx = firstPhaseIndex(tag.value),
                      case let .sources(t) = buildPhases[idx] else { fatalError() }
                return t
            }
            set {
                guard let idx = firstPhaseIndex(tag.value) else {
                    fatalError()
                }
                buildPhases[idx] = .sources(newValue)
            }
        }

        public subscript(buildPhase tag: BuildPhaseTag<FrameworksBuildPhase>) -> FrameworksBuildPhase {
            get {
                guard let idx = firstPhaseIndex(tag.value),
                      case let .frameworks(t) = buildPhases[idx] else { fatalError() }
                return t
            }
            set {
                guard let idx = firstPhaseIndex(tag.value) else {
                    fatalError()
                }
                buildPhases[idx] = .frameworks(newValue)
            }
        }

        public subscript(buildPhase tag: BuildPhaseTag<CopyBundleResourcesBuildPhase>) -> CopyBundleResourcesBuildPhase {
            get {
                guard let idx = firstPhaseIndex(tag.value),
                      case let .copyBundleResources(t) = buildPhases[idx] else { fatalError() }
                return t
            }
            set {
                guard let idx = firstPhaseIndex(tag.value) else {
                    fatalError()
                }
                buildPhases[idx] = .copyBundleResources(newValue)
            }
        }

        public subscript(buildPhase tag: BuildPhaseTag<CopyFilesBuildPhase>) -> CopyFilesBuildPhase {
            get {
                guard let idx = firstPhaseIndex(tag.value),
                      case let .copyFiles(t) = buildPhases[idx] else { fatalError() }
                return t
            }
            set {
                guard let idx = firstPhaseIndex(tag.value) else {
                    fatalError()
                }
                buildPhases[idx] = .copyFiles(newValue)
            }
        }

        public subscript(buildPhase tag: BuildPhaseTag<ShellScriptBuildPhase>) -> ShellScriptBuildPhase {
            get {
                guard let idx = firstPhaseIndex(tag.value),
                      case let .shellScript(t) = buildPhases[idx] else { fatalError() }
                return t
            }
            set {
                guard let idx = firstPhaseIndex(tag.value) else {
                    fatalError()
                }
                buildPhases[idx] = .shellScript(newValue)
            }
        }

        @discardableResult public mutating func withFrameworksBuildPhase<T>(_ modify: (inout FrameworksBuildPhase) -> T) -> T {
            let phaseTag = firstPhaseTag({
                switch $0 {
                case .frameworks(_): return true
                default: return false
                }
            }) ?? (addFrameworksBuildPhase { id in FrameworksBuildPhase(id: id) })

            return modify(&self[buildPhase: phaseTag])
        }

        @discardableResult public mutating func withCopyBundleResourcesBuildPhase<T>(_ modify: (inout CopyBundleResourcesBuildPhase) -> T) -> T {
            let phaseTag = firstPhaseTag({
                switch $0 {
                case .copyBundleResources(_): return true
                default: return false
                }
            }) ?? (addCopyBundleResourcesBuildPhase { id in CopyBundleResourcesBuildPhase(id: id) })

            return modify(&self[buildPhase: phaseTag])
        }

        @discardableResult public mutating func withHeadersBuildPhase<T>(_ modify: (inout HeadersBuildPhase) -> T) -> T {
            let phaseTag = firstPhaseTag({
                switch $0 {
                case .headers(_): return true
                default: return false
                }
            }) ?? (addHeadersBuildPhase { id in HeadersBuildPhase(id: id) })

            return modify(&self[buildPhase: phaseTag])
        }

        @discardableResult public mutating func withSourcesBuildPhase<T>(_ modify: (inout SourcesBuildPhase) -> T) -> T {

            let phaseTag = firstPhaseTag({
                switch $0 {
                case .sources(_): return true
                default: return false
                }
            }) ?? (addSourcesBuildPhase { id in SourcesBuildPhase(id: id) })

            return modify(&self[buildPhase: phaseTag])
        }

        private func firstPhaseTag<T>(_ pred: (BuildPhase) -> Bool) -> BuildPhaseTag<T>? {
            for buildPhase in buildPhases {
                if pred(buildPhase) {
                    return BuildPhaseTag<T>(value: buildPhase.common.id)
                }
            }
            return nil
        }

        private func firstPhaseIndex(_ guid: GUID) -> Int? {
            return buildPhases.firstIndex(where: { $0.common.id == guid })
        }


        // MARK: - BuildRule

        private var nextBuildRuleId: GUID {
            return "\(self.id.value)::BUILDRULE_\(buildRules.count)"
        }

        /// Adds a build rule with an input specifying files to match and an action specifying either a compiler or a shell script.
        @discardableResult public mutating func addBuildRule(_ create: CreateFn<BuildRule>) -> Tag<BuildRule> {
            let buildRule = create(nextBuildRuleId)
            buildRules.append(buildRule)
            return .init(value: buildRule.id)
        }

        public subscript(buildRule tag: Tag<BuildRule>) -> BuildRule {
            get { buildRules[id: tag.value] }
            set { buildRules[id: tag.value] = newValue }
        }

        // MARK: - TargetDependency

        /// Adds a dependency on another target.  It is the caller's responsibility to avoid creating dependency cycles.  A dependency of one target on another ensures that the other target is built first.
        public mutating func addTargetDependency(_ dependency: TargetDependency) {
            dependencies.append(dependency)
        }


        /// Adds a dependency on another target.  It is the caller's responsibility to avoid creating dependency cycles.  A dependency of one target on another ensures that the other target is built first. If `linkProduct` is true, the receiver will also be configured to link against the product produced by the other target (this presumes that the product type is one that can be linked against).
        @discardableResult public mutating func addDependency(on targetId: GUID, platformFilters: Set<PlatformFilter>, linkProduct: Bool = false) -> TargetDependency {
            let dependency = TargetDependency(targetId: targetId, platformFilters: platformFilters)
            addTargetDependency(dependency)
            if linkProduct {
                withFrameworksBuildPhase { phase in
                    phase.common.addBuildFile { id in BuildFile(id: id, ref: .targetProduct(id: targetId), platformFilters: platformFilters) }
                }
            }
            return dependency
        }
    }

    /// An Xcode target, representing a single entity to build.
    public struct Target: Common, Identifiable, Sendable, Hashable {
        /// Product type identifiers are extensible; Xcode and plugins can introduce new ones.
        public struct ProductType: RawRepresentable, Sendable, Hashable, Codable {
            public var rawValue: String

            public init(rawValue: String) { self.rawValue = rawValue }

            public init(from decoder: any Decoder) throws {
                rawValue = try decoder.singleValueContainer().decode(String.self)
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(rawValue)
            }

            public static let application = Self(rawValue: "com.apple.product-type.application")
            public static let staticArchive = Self(rawValue: "com.apple.product-type.library.static")
            public static let commonStaticArchive = Self(rawValue: "org.swift.product-type.library.static")
            public static let commonObject = Self(rawValue: "org.swift.product-type.common.object")
            public static let objectLibrary = Self(rawValue: "org.swift.product-type.library.object")
            public static let objectFile = Self(rawValue: "com.apple.product-type.objfile")
            public static let dynamicLibrary = Self(rawValue: "com.apple.product-type.library.dynamic")
            public static let framework = Self(rawValue: "com.apple.product-type.framework")
            public static let executable = Self(rawValue: "com.apple.product-type.tool")
            public static let hostBuildTool = Self(rawValue: "com.apple.product-type.tool.host-build")
            public static let unitTest = Self(rawValue: "com.apple.product-type.bundle.unit-test")
            public static let swiftpmTestRunner = Self(rawValue: "com.apple.product-type.tool.swiftpm-test-runner")
            public static let bundle = Self(rawValue: "com.apple.product-type.bundle")
            public static let packageProduct = Self(rawValue: "packageProduct")
            public static let appExtension = Self(rawValue: "com.apple.product-type.app-extension")
            public static let uiTest = Self(rawValue: "com.apple.product-type.bundle.ui-testing")
            public static let watchApplication = Self(rawValue: "com.apple.product-type.application.watchapp2")
            public static let watchExtension = Self(rawValue: "com.apple.product-type.watchkit2-extension")
        }

        public var common: TargetCommon
        public var productName: String {
            get { productReference.name }
            set { productReference.name = newValue }
        }
        public var productType: ProductType
        public var productReference: ProductReference
        var omitEmptyProvisioningSourceData = false
        public var provisioningSourceData: [ProvisioningSourceData] = []
        public var isPackageTarget: Bool = false
        public var classPrefix: String? = nil
        public var predominantSourceCodeLanguage: String? = nil
        public var performanceTestsBaselinesPath: String? = nil
        public var approvedByUser: Bool

        /// Package products can have an optional reference to a dynamic target which allows building the same product dynamically instead.
        public var dynamicTargetVariantId: Optional<GUID>

        public var id: GUID { return common.id }

        public init(
            id: GUID,
            productType: ProductType,
            name: String,
            productName: String,
            approvedByUser: Bool = true,
            buildConfigs: [BuildConfig] = [],
            buildPhases: [BuildPhase] = [],
            buildRules: [BuildRule] = [],
            dependencies: [TargetDependency] = []
        ) {
            self.common = TargetCommon(id: id, name: name, buildConfigs: buildConfigs, buildPhases: buildPhases, buildRules: buildRules, dependencies: dependencies)
            self.productType = productType
            self.productReference = ProductReference(id: .init("PRODUCTREF-\(id.value)"), name: productName)
            self.approvedByUser = approvedByUser
            self.dynamicTargetVariantId = nil
        }

        /// Convenience function to add a file reference to the Frameworks build phase, after creating it if needed.
        @discardableResult public mutating func addLibrary(_ create: CreateFn<BuildFile>) -> BuildFile {
            // need to access the first build phase, or create one if it doesn't exist, then edit in place
            common.withFrameworksBuildPhase { phase in
                phase.common.addBuildFile(create)
            }
        }

        @discardableResult public mutating func addResourceFile(_ create: CreateFn<BuildFile>) -> BuildFile {
            // need to access the first build phase, or create one if it doesn't exist, then edit in place
            common.withCopyBundleResourcesBuildPhase { phase in
                phase.common.addBuildFile(create)
            }
        }

        @discardableResult public mutating func addSourceFile(_ create: CreateFn<BuildFile>) -> BuildFile {
            // need to access the first build phase, or create one if it doesn't exist, then edit in place
            common.withSourcesBuildPhase { phase in
                phase.common.addBuildFile(create)
            }
        }
    }

    public struct AggregateTarget: Common, Identifiable, Sendable, Hashable {
        public var common: TargetCommon
        public var id: GUID { common.id }

        public init(
            id: GUID,
            name: String,
            buildConfigs: [BuildConfig] = [],
            buildPhases: [BuildPhase] = [],
            buildRules: [BuildRule] = [],
            dependencies: [TargetDependency] = []
        ) {
            self.common = TargetCommon(id: id, name: name, buildConfigs: buildConfigs, buildPhases: buildPhases, buildRules: buildRules, dependencies: dependencies)
        }
    }
}

extension XPIF.BaseTarget: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: StringKey.self)
        let type = try container.decode(String.self, forKey: StringKey("type"))
        switch type {
        case "standard", "packageProduct": self = .target(try XPIF.Target(from: decoder))
        case "aggregate": self = .aggregate(try XPIF.AggregateTarget(from: decoder))
        case "external": self = .external(try XPIF.ExternalTarget(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: StringKey("type"), in: container, debugDescription: "Unknown target type: \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .target(let target): try target.encode(to: encoder)
        case .aggregate(let target): try target.encode(to: encoder)
        case .external(let target): try target.encode(to: encoder)
        }
    }
}

extension XPIF.Target: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let id = try container.decode(XPIF.GUID.self, forKey: .guid)
        let dependencies = try container.decodeIfPresent([XPIF.TargetDependency].self, forKey: .dependencies) ?? []
        let buildConfigs = try container.decodeIfPresent([XPIF.BuildConfig].self, forKey: .buildConfigurations) ?? []
        let buildPhases: [XPIF.BuildPhase]
        let buildRules: [XPIF.BuildRule]
        let name = try container.decode(String.self, forKey: .name)

        let productType = try container.decode(String.self, forKey: .type)
        switch productType {
        case "packageProduct":
            buildRules = []
            if let phase = try container.decodeIfPresent(XPIF.FrameworksBuildPhase.self, forKey: .frameworksBuildPhase) {
                buildPhases = [.frameworks(phase)]
            } else {
                buildPhases = []
            }
            self.productReference = .init(id: .init("PRODUCTREF-\(id.value)"), name: "")
            self.productType = .packageProduct
        default:
            buildPhases = try container.decodeIfPresent([XPIF.BuildPhase].self, forKey: .buildPhases) ?? []
            buildRules = try container.decodeIfPresent([XPIF.BuildRule].self, forKey: .buildRules) ?? []
            self.productType = try container.decode(ProductType.self, forKey: .productTypeIdentifier)
            self.productReference = try container.decode(XPIF.ProductReference.self, forKey: .productReference)
        }
        self.common = .init(id: id, name: name, buildConfigs: buildConfigs, buildPhases: buildPhases, buildRules: buildRules, dependencies: dependencies)
        self.dynamicTargetVariantId = try container.decodeIfPresent(XPIF.GUID.self, forKey: .dynamicTargetVariantGuid)
        self.approvedByUser = try container.decodePIFBool(forKey: .approvedByUser, default: true)
        self.provisioningSourceData = try container.decodeIfPresent([XPIF.ProvisioningSourceData].self, forKey: .provisioningSourceData) ?? []
        self.omitEmptyProvisioningSourceData = !container.contains(.provisioningSourceData)
        self.isPackageTarget = try container.decodePIFBool(forKey: .isPackageTarget)
        self.classPrefix = try container.decodeIfPresent(String.self, forKey: .classPrefix)
        self.predominantSourceCodeLanguage = try container.decodeIfPresent(String.self, forKey: .predominantSourceCodeLanguage)
        self.performanceTestsBaselinesPath = try container.decodeIfPresent(String.self, forKey: .performanceTestsBaselinesPath)
        self.customTasks = try container.decodeIfPresent([XPIF.CustomTask].self, forKey: .customTasks) ?? []
        self.common.additionalFields = try decodeAdditionalFields(from: decoder, excluding: CodingKeys.self)
        self.common.explicitDefaults = try decodeExplicitDefaults(from: decoder, defaults: ["approvedByUser": .string("true"), "customTasks": .array([])])
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeExplicitDefaults(common.explicitDefaults, to: encoder)
        try encodeAdditionalFields(self.common.additionalFields, to: encoder, excluding: CodingKeys.self)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .guid)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.dependencies, forKey: .dependencies)
        try container.encode(self.buildConfigs, forKey: .buildConfigurations)
        try container.encodeIfPresent(self.dynamicTargetVariantId, forKey: .dynamicTargetVariantGuid)
        if !approvedByUser { try container.encode("false", forKey: .approvedByUser) }
        if !self.customTasks.isEmpty { try container.encode(self.customTasks, forKey: .customTasks) }

        switch self.productType {
        case .packageProduct:
            try container.encode("packageProduct", forKey: .type)
            if let first = self.buildPhases.first,
               case let .frameworks(phase) = first {
                try container.encode(phase, forKey: .frameworksBuildPhase)
            }

        default:
            try container.encode("standard", forKey: .type)
            try container.encode(self.buildPhases, forKey: .buildPhases)
            try container.encode(self.buildRules, forKey: .buildRules)
            try container.encode(self.productType, forKey: .productTypeIdentifier)
            try container.encode(productReference, forKey: .productReference)
            if !omitEmptyProvisioningSourceData || !provisioningSourceData.isEmpty {
                try container.encode(provisioningSourceData, forKey: .provisioningSourceData)
            }
            if isPackageTarget { try container.encode("true", forKey: .isPackageTarget) }
            try container.encodeIfPresent(classPrefix, forKey: .classPrefix)
            try container.encodeIfPresent(predominantSourceCodeLanguage, forKey: .predominantSourceCodeLanguage)
            try container.encodeIfPresent(performanceTestsBaselinesPath, forKey: .performanceTestsBaselinesPath)
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case guid
        case name
        case dependencies
        case buildRules
        case buildPhases
        case frameworksBuildPhase
        case buildConfigurations
        case type
        case dynamicTargetVariantGuid
        case approvedByUser
        case customTasks
        case productReference
        case productTypeIdentifier
        case provisioningSourceData, isPackageTarget, classPrefix
        case predominantSourceCodeLanguage, performanceTestsBaselinesPath
    }
}

extension XPIF.AggregateTarget: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(XPIF.GUID.self, forKey: .guid)
        let name = try container.decode(String.self, forKey: .name)
        let dependencies = try container.decodeIfPresent([XPIF.TargetDependency].self, forKey: .dependencies) ?? []
        let buildRules = try container.decodeIfPresent([XPIF.BuildRule].self, forKey: .buildRules) ?? []
        let buildPhases = try container.decodeIfPresent([XPIF.BuildPhase].self, forKey: .buildPhases) ?? []
        let buildConfigs = try container.decodeIfPresent([XPIF.BuildConfig].self, forKey: .buildConfigurations) ?? []
        let customTasks = try container.decodeIfPresent([XPIF.CustomTask].self, forKey: .customTasks) ?? []

        self.common = XPIF.TargetCommon(
            id: id,
            name: name,
            buildConfigs: buildConfigs,
            buildPhases: buildPhases,
            buildRules: buildRules,
            dependencies: dependencies,
            customTasks: customTasks
        )
        self.common.additionalFields = try decodeAdditionalFields(from: decoder, excluding: CodingKeys.self)
        self.common.explicitDefaults = try decodeExplicitDefaults(from: decoder, defaults: ["approvedByUser": .string("true"), "customTasks": .array([])])
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeExplicitDefaults(common.explicitDefaults, to: encoder)
        try encodeAdditionalFields(self.common.additionalFields, to: encoder, excluding: CodingKeys.self)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("aggregate", forKey: .type)
        try container.encode(self.id, forKey: .guid)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.dependencies, forKey: .dependencies)
        try container.encode(self.buildRules, forKey: .buildRules)
        try container.encode(self.buildPhases, forKey: .buildPhases)
        try container.encode(self.buildConfigs, forKey: .buildConfigurations)
        if !self.customTasks.isEmpty { try container.encode(self.customTasks, forKey: .customTasks) }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case type
        case guid
        case name
        case dependencies
        case buildRules
        case buildPhases
        case buildConfigurations
        case customTasks
    }
}
