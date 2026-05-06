import Foundation

/// Output of `Scanner` — a normalised view of every AppIntents declaration
/// found in a source tree. The shapes here intentionally avoid mirroring
/// any Apple SPI; they are the inputs that `Emitter` consumes to produce
/// the on-disk `Metadata.appintents/` bundle.
public struct ScannedModule: Sendable, Equatable {
    public var intents: [ScannedIntent]
    public var shortcutsProviders: [ScannedShortcutsProvider]
    public var entities: [ScannedEntity]
    public var enums: [ScannedEnum]
    public var packages: [ScannedPackage]

    public init(
        intents: [ScannedIntent] = [],
        shortcutsProviders: [ScannedShortcutsProvider] = [],
        entities: [ScannedEntity] = [],
        enums: [ScannedEnum] = [],
        packages: [ScannedPackage] = []
    ) {
        self.intents = intents
        self.shortcutsProviders = shortcutsProviders
        self.entities = entities
        self.enums = enums
        self.packages = packages
    }

    public var isEmpty: Bool {
        intents.isEmpty
            && shortcutsProviders.isEmpty
            && entities.isEmpty
            && enums.isEmpty
            && packages.isEmpty
    }

    public mutating func merge(_ other: ScannedModule) {
        intents.append(contentsOf: other.intents)
        shortcutsProviders.append(contentsOf: other.shortcutsProviders)
        entities.append(contentsOf: other.entities)
        enums.append(contentsOf: other.enums)
        packages.append(contentsOf: other.packages)
    }
}

/// Swift declaration kind. Used by the mangled-name calculator to pick
/// the trailing suffix character: `V` (struct), `C` (class), `O` (enum).
public enum ScannedDeclKind: String, Sendable, Equatable {
    case `struct`
    case `class`
    case `enum`

    /// Trailing character used by Swift's symbol mangling.
    public var mangledSuffix: Character {
        switch self {
        case .struct: return "V"
        case .class: return "C"
        case .enum: return "O"
        }
    }
}

public struct ScannedPackage: Sendable, Equatable {
    public var typeName: String
    public var kind: ScannedDeclKind
    public var module: String

    public init(typeName: String, kind: ScannedDeclKind = .struct, module: String = "") {
        self.typeName = typeName
        self.kind = kind
        self.module = module
    }
}

public struct ScannedIntent: Sendable, Equatable {
    public var typeName: String
    public var kind: ScannedDeclKind
    public var module: String
    public var title: String?
    public var descriptionText: String?
    public var categoryName: String?
    public var openAppWhenRun: Bool?
    public var isDiscoverable: Bool?
    public var protocolNames: [String]
    public var parameters: [ScannedParameter]
    public var returnsValue: Bool

    public init(
        typeName: String,
        kind: ScannedDeclKind = .struct,
        module: String = "",
        title: String? = nil,
        descriptionText: String? = nil,
        categoryName: String? = nil,
        openAppWhenRun: Bool? = nil,
        isDiscoverable: Bool? = nil,
        protocolNames: [String] = [],
        parameters: [ScannedParameter] = [],
        returnsValue: Bool = false
    ) {
        self.typeName = typeName
        self.kind = kind
        self.module = module
        self.title = title
        self.descriptionText = descriptionText
        self.categoryName = categoryName
        self.openAppWhenRun = openAppWhenRun
        self.isDiscoverable = isDiscoverable
        self.protocolNames = protocolNames
        self.parameters = parameters
        self.returnsValue = returnsValue
    }
}

public struct ScannedParameter: Sendable, Equatable {
    public var propertyName: String
    public var typeName: String
    public var title: String?
    public var descriptionText: String?
    public var defaultValueExpression: String?
    public var isOptional: Bool

    public init(
        propertyName: String,
        typeName: String,
        title: String? = nil,
        descriptionText: String? = nil,
        defaultValueExpression: String? = nil,
        isOptional: Bool = false
    ) {
        self.propertyName = propertyName
        self.typeName = typeName
        self.title = title
        self.descriptionText = descriptionText
        self.defaultValueExpression = defaultValueExpression
        self.isOptional = isOptional
    }
}

public struct ScannedShortcutsProvider: Sendable, Equatable {
    public var typeName: String
    public var kind: ScannedDeclKind
    public var module: String
    public var shortcuts: [ScannedShortcut]

    public init(
        typeName: String,
        kind: ScannedDeclKind = .struct,
        module: String = "",
        shortcuts: [ScannedShortcut] = []
    ) {
        self.typeName = typeName
        self.kind = kind
        self.module = module
        self.shortcuts = shortcuts
    }
}

public struct ScannedShortcut: Sendable, Equatable {
    public var intentTypeName: String
    public var phrases: [String]
    public var shortTitle: String?
    public var systemImageName: String?

    public init(
        intentTypeName: String,
        phrases: [String] = [],
        shortTitle: String? = nil,
        systemImageName: String? = nil
    ) {
        self.intentTypeName = intentTypeName
        self.phrases = phrases
        self.shortTitle = shortTitle
        self.systemImageName = systemImageName
    }
}

public struct ScannedEntity: Sendable, Equatable {
    public var typeName: String
    public var kind: ScannedDeclKind
    public var module: String
    public var protocolNames: [String]

    public init(
        typeName: String,
        kind: ScannedDeclKind = .struct,
        module: String = "",
        protocolNames: [String] = []
    ) {
        self.typeName = typeName
        self.kind = kind
        self.module = module
        self.protocolNames = protocolNames
    }
}

public struct ScannedEnum: Sendable, Equatable {
    public var typeName: String
    public var module: String
    public var protocolNames: [String]
    public var cases: [String]

    public init(typeName: String, module: String = "", protocolNames: [String] = [], cases: [String] = []) {
        self.typeName = typeName
        self.module = module
        self.protocolNames = protocolNames
        self.cases = cases
    }

    public var kind: ScannedDeclKind { .enum }
}
