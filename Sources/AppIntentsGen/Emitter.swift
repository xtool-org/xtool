import Foundation

/// Writes the on-disk `Metadata.appintents/` bundle from a `ScannedModule`.
///
/// **Schema source.** Apple's `appintentsmetadataprocessor` emits two files:
/// `extract.actionsdata` (JSON text) and `version.json`. The exact shapes
/// are not documented; the layout below is reverse-engineered from a
/// shipping reference IPA (Wispr Flow 1.55) and validated against the
/// AppIntents-using apps inside it (`StartStopRecordingAppIntent`,
/// `CreateNoteViaTextAppIntent`, `NoteAppIntent` in the widget extension).
/// The user's `scripts/appintents_audit.py` was used to extract those
/// references.
///
/// We deliberately diverge from Apple's output in only one place: the
/// `generator` block names ourselves (`xtool-appintents-gen`) rather than
/// `xcode-tools`, and the version field carries the swift toolchain
/// identifier instead of the Xcode build number. Apple's daemon ignores
/// unrecognised generator strings; the field exists only for diagnostics.
///
/// **Format note.** Despite the `extract.actionsdata` extension, the file
/// is plain UTF-8 JSON — not a property list. Earlier xtool revisions wrote
/// a binary plist here; iOS Shortcuts cannot parse that and silently skips
/// indexing the bundle, which was the root cause of intents never appearing
/// in the Shortcuts action picker.
public struct Emitter: Sendable {

    /// `extract.actionsdata.version` integer. Wispr Flow ships value `1`;
    /// the schema has been stable across iOS 17 / 18 / 26 in our captures.
    public static let actionsDataVersion: Int = 1

    /// `version.json.version` string. Apple writes a string (`"3.0"`),
    /// not an integer. Bumping this should only happen when Apple ships
    /// a schema-breaking change in a new iOS major.
    public static let versionJSONVersion: String = "3.0"

    public struct Inputs: Sendable {
        /// Bundle identifier as produced by the planner (un-prefixed; the
        /// AutoSigner rewrites this to the team-prefixed form before signing).
        public let bundleIdentifier: String

        /// Swift module name (user-visible SPM library).
        public let moduleName: String

        /// Free-form toolchain stamp, e.g. `swift-6.3.1`. Surfaced in
        /// `version.json.toolsVersion` for diagnostics; iOS does not parse it.
        public let toolchainVersion: String

        /// Minimum deployment target, e.g. `17.0`.
        public let deploymentTarget: String

        /// Platform family; only `iOS` is exercised today.
        public let platformFamily: String

        /// `true` if this product is an app extension (widget appex etc.).
        /// Affects per-action `supportedModes`: app extension intents default
        /// to `2` (widget configuration), main-app intents to `1`.
        public let isAppExtension: Bool

        public init(
            bundleIdentifier: String,
            moduleName: String,
            toolchainVersion: String,
            deploymentTarget: String,
            platformFamily: String = "iOS",
            isAppExtension: Bool = false
        ) {
            self.bundleIdentifier = bundleIdentifier
            self.moduleName = moduleName
            self.toolchainVersion = toolchainVersion
            self.deploymentTarget = deploymentTarget
            self.platformFamily = platformFamily
            self.isAppExtension = isAppExtension
        }
    }

    public init() {}

    /// Materialise the bundle. `outputDir` is the desired
    /// `Metadata.appintents` directory; the emitter creates it (replacing
    /// any existing one) and writes `extract.actionsdata` + `version.json`
    /// inside. No `*.lproj/` subdirectory is written — phrase data lives
    /// in `extract.actionsdata.autoShortcuts` per Apple's current schema.
    public func emit(
        module: ScannedModule,
        inputs: Inputs,
        outputDir: URL
    ) throws {
        try? FileManager.default.removeItem(at: outputDir)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        try writeActionsData(module: module, inputs: inputs, into: outputDir)
        try writeVersionJSON(inputs: inputs, into: outputDir)
    }

    // MARK: - extract.actionsdata

    private func writeActionsData(
        module: ScannedModule,
        inputs: Inputs,
        into outputDir: URL
    ) throws {
        // `actions` is keyed by the bare type name (no module prefix). The
        // `identifier` field inside each action also carries the bare name.
        // The `fullyQualifiedTypeName` field is what carries the namespace.
        var actions: [String: Any] = [:]
        for intent in module.intents {
            actions[intent.typeName] = actionDictionary(for: intent, inputs: inputs)
        }

        var entities: [String: Any] = [:]
        for entity in module.entities {
            entities[entity.typeName] = entityDictionary(for: entity, inputs: inputs)
        }

        let provider = module.shortcutsProviders.first
        let autoShortcuts = (provider?.shortcuts ?? []).map { autoShortcutDictionary(for: $0) }
        let autoShortcutProviderMangledName: String = {
            guard let provider else { return "" }
            return MangledName.encode(
                module: provider.module.isEmpty ? inputs.moduleName : provider.module,
                typeName: provider.typeName,
                kind: provider.kind
            )
        }()

        let payload: [String: Any] = [
            "version": Self.actionsDataVersion,
            "generator": [
                "name": "xtool-appintents-gen",
                "version": inputs.toolchainVersion,
            ] as [String: Any],
            "shortcutTileColor": 14,
            "actions": actions,
            "entities": entities,
            "enums": module.enums.map(enumDictionary),
            "queries": [String: Any](),
            "autoShortcuts": autoShortcuts,
            "autoShortcutProviderMangledName": autoShortcutProviderMangledName,
            "negativePhrases": [Any](),
            "assistantEntities": [Any](),
            "assistantIntents": [Any](),
            "assistantIntentNegativePhrases": [Any](),
            "packages": module.packages.map { package in
                [
                    "identifier": package.typeName,
                    "mangledTypeName": MangledName.encode(
                        module: package.module.isEmpty ? inputs.moduleName : package.module,
                        typeName: package.typeName,
                        kind: package.kind
                    )
                ] as [String: Any]
            },
        ]

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        try data.write(to: outputDir.appendingPathComponent("extract.actionsdata"))
    }

    private func actionDictionary(
        for intent: ScannedIntent,
        inputs: Inputs
    ) -> [String: Any] {
        let intentModule = intent.module.isEmpty ? inputs.moduleName : intent.module
        let mangled = MangledName.encode(
            module: intentModule,
            typeName: intent.typeName,
            kind: intent.kind
        )

        let isDiscoverable = intent.isDiscoverable ?? true
        let openAppWhenRun = intent.openAppWhenRun ?? false

        // Apple's bitfield: 0 = void perform(), 4 = perform returns a value
        // through `IntentResult & ReturnsValue<T>`. Higher bits cover dialogs
        // / opens-intent / etc. — leave them off until we capture a real
        // counter-example.
        let outputFlags: Int = intent.returnsValue ? 4 : 0

        // App-extension intents (e.g. WidgetConfigurationIntent inside a
        // widget appex) get supportedModes=2; ordinary AppIntents get 1.
        // Specialized intents like AudioRecordingIntent MUST run in the host
        // app to access the microphone; force mode 1 for those.
        var supportedModes: Int = inputs.isAppExtension ? 2 : 1
        if intent.protocolNames.contains(where: { $0.hasSuffix("AudioRecordingIntent") }) {
            supportedModes = 1
        }

        let titleString = intent.title ?? intent.typeName
        let descriptionString = intent.descriptionText ?? ""

        var dict: [String: Any] = [
            "identifier": intent.typeName,
            "fullyQualifiedTypeName": "\(intentModule).\(intent.typeName)",
            "mangledTypeName": mangled,
            "mangledTypeNameV2": mangled,
            "mangledTypeNameByBundleIdentifier": [String: Any](),
            "mangledTypeNameByBundleIdentifierV2": [String: Any](),
            "title": localizableString(titleString),
            "descriptionMetadata": [
                "descriptionText": localizableString(descriptionString),
                "searchKeywords": [Any](),
            ] as [String: Any],
            "visibilityMetadata": [
                "isDiscoverable": isDiscoverable,
                "assistantOnly": false,
            ] as [String: Any],
            "availabilityAnnotations": availabilityAnnotations(),
            "isDiscoverable": isDiscoverable,
            "isAuthPolExplicit": false,
            "authenticationPolicy": 0,
            "openAppWhenRun": openAppWhenRun,
            "outputFlags": outputFlags,
            "presentationStyle": 0,
            "supportedModes": supportedModes,
            "requiredCapabilities": [Any](),
            "effectiveBundleIdentifiers": [Any](),
            "systemProtocols": SystemProtocols.resolve(for: intent.protocolNames),
            "systemProtocolMetadata": SystemProtocols.metadata(for: intent.protocolNames),
            "systemProtocolMetadataV2": SystemProtocols.metadata(for: intent.protocolNames),
            "typeSpecificMetadata": [Any](),
            "assistantDefinedSchemas": [Any](),
            "assistantDefinedSchemaTraits": [Any](),
            "parameters": intent.parameters.map(parameterDictionary),
        ]

        // Surface the action's return value as a typed magic variable in
        // Shortcuts. Shape mirrors `parameterDictionary`'s `valueType`
        // wrapper. `typeIdentifier: 0` is a placeholder; if Shortcuts hides
        // the variable or types it as opaque, audit a real reference IPA's
        // `extract.actionsdata` and patch the type code.
        if intent.returnsValue {
            dict["outputType"] = [
                "primitive": [
                    "wrapper": [
                        "typeIdentifier": 0,
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any]
        }

        // Note: Wispr Flow's reference IPA never emits a `categoryName` key
        // on action entries. Apple may surface IntentDescription's
        // categoryName argument through a separate channel (e.g. donated
        // category index) — emitting an unknown key here risks Shortcuts
        // rejecting the entry. Drop it until we capture a counter-example.
        _ = intent.categoryName
        return dict
    }

    private func parameterDictionary(_ parameter: ScannedParameter) -> [String: Any] {
        // `valueType` is a discriminated union in Apple's schema. The full
        // type registry is not exposed here; we emit the primitive typeIdentifier
        // form with `0` as a generic placeholder, which iOS appears to tolerate
        // for parameters that are not actively used in voice/dialog flows.
        let valueType: [String: Any] = [
            "primitive": [
                "wrapper": [
                    "typeIdentifier": 0,
                ] as [String: Any],
            ] as [String: Any],
        ]

        var dict: [String: Any] = [
            "name": parameter.propertyName,
            "isOptional": parameter.isOptional,
            "isInput": false,
            "capabilities": 0,
            "dynamicOptionsSupport": 0,
            "inputConnectionBehavior": 0,
            "title": localizableString(parameter.title ?? parameter.propertyName),
            "valueType": valueType,
            "resolvableInputTypes": [Any](),
            "typeSpecificMetadata": [Any](),
        ]
        if let description = parameter.descriptionText {
            dict["descriptionMetadata"] = [
                "descriptionText": localizableString(description),
                "searchKeywords": [Any](),
            ] as [String: Any]
        }
        if let defaultExpr = parameter.defaultValueExpression {
            dict["defaultValueExpression"] = defaultExpr
        }
        return dict
    }

    private func entityDictionary(
        for entity: ScannedEntity,
        inputs: Inputs
    ) -> [String: Any] {
        let entityModule = entity.module.isEmpty ? inputs.moduleName : entity.module
        let mangled = MangledName.encode(
            module: entityModule,
            typeName: entity.typeName,
            kind: entity.kind
        )
        return [
            "identifier": entity.typeName,
            "fullyQualifiedTypeName": "\(entityModule).\(entity.typeName)",
            "mangledTypeName": mangled,
            "mangledTypeNameV2": mangled,
            "title": localizableString(entity.typeName),
            "availabilityAnnotations": availabilityAnnotations(),
        ]
    }

    private func enumDictionary(_ enumDecl: ScannedEnum) -> [String: Any] {
        [
            "identifier": enumDecl.typeName,
            "cases": enumDecl.cases.map { caseName -> [String: Any] in
                [
                    "identifier": caseName,
                    "title": localizableString(caseName),
                ]
            },
            "title": localizableString(enumDecl.typeName),
        ]
    }

    private func autoShortcutDictionary(for shortcut: ScannedShortcut) -> [String: Any] {
        var dict: [String: Any] = [
            "actionIdentifier": shortcut.intentTypeName,
            "phraseTemplates": shortcut.phrases.map { phrase -> [String: Any] in
                [
                    "key": normalisePhrase(phrase),
                    "alternatives": [Any](),
                ]
            },
            "availabilityAnnotations": availabilityAnnotations(),
        ]
        if let shortTitle = shortcut.shortTitle {
            dict["shortTitle"] = localizableString(shortTitle)
        }
        if let imageName = shortcut.systemImageName {
            dict["systemImageName"] = imageName
        }
        return dict
    }

    // MARK: - version.json

    private func writeVersionJSON(inputs: Inputs, into outputDir: URL) throws {
        let payload: [String: Any] = [
            "version": Self.versionJSONVersion,
            "toolsVersion": inputs.toolchainVersion,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: outputDir.appendingPathComponent("version.json"))
    }

    // MARK: - Helpers

    /// Apple wraps every localizable string as `{key, alternatives}`. The
    /// `key` is either an inline literal (when no string catalog is present)
    /// or the catalog identifier; `alternatives` is reserved for variant
    /// phrasings (Siri ranking) and is empty in the absence of source data.
    private func localizableString(_ value: String) -> [String: Any] {
        [
            "key": value,
            "alternatives": [Any](),
        ]
    }

    /// `availabilityAnnotations` is a single-key map under
    /// `LNPlatformNameWildcard` keyed by `introducedVersion` set to `*`.
    /// Apple uses richer payloads for `@available(iOS X.Y, *)`-gated
    /// declarations; we keep the wildcard form until the scanner captures
    /// availability attributes.
    private func availabilityAnnotations() -> [String: Any] {
        [
            "LNPlatformNameWildcard": [
                "introducedVersion": "*",
            ] as [String: Any],
        ]
    }

    /// `\(.applicationName)` → `${applicationName}`. Apple's `phraseTemplates`
    /// embed `${name}`-style placeholders that the Shortcuts NLU substitutes
    /// at runtime (`applicationName`, `parameter:<name>`, etc.).
    private func normalisePhrase(_ phrase: String) -> String {
        var out = ""
        var index = phrase.startIndex
        while index < phrase.endIndex {
            if phrase[index] == "\\",
               let nextIndex = phrase.index(index, offsetBy: 1, limitedBy: phrase.endIndex),
               nextIndex < phrase.endIndex,
               phrase[nextIndex] == "(" {
                if let closeIndex = phrase[nextIndex...].firstIndex(of: ")") {
                    var inner = String(phrase[phrase.index(after: nextIndex)..<closeIndex])
                    if inner.hasPrefix(".") { inner.removeFirst() }
                    out.append("${\(inner)}")
                    index = phrase.index(after: closeIndex)
                    continue
                }
            }
            out.append(phrase[index])
            index = phrase.index(after: index)
        }
        return out
    }
}
