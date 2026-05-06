import Foundation
import Testing

@testable import AppIntentsGen

@Suite("Emitter") struct EmitterTests {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xtool-appintents-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeInputs(isAppExtension: Bool = false) -> Emitter.Inputs {
        Emitter.Inputs(
            bundleIdentifier: "com.example.iMoonshine",
            moduleName: "iMoonshine",
            toolchainVersion: "swift-6.3.1",
            deploymentTarget: "17.0",
            isAppExtension: isAppExtension
        )
    }

    @Test("Emits JSON extract.actionsdata + version.json with the expected top-level keys")
    func emitsJSONFiles() throws {
        let module = ScannedModule(
            intents: [
                ScannedIntent(
                    typeName: "ToggleRecordingIntent",
                    kind: .struct,
                    title: "Toggle iMoonshine",
                    descriptionText: "Start or stop recording.",
                    categoryName: "iMoonshine",
                    openAppWhenRun: false,
                    isDiscoverable: true,
                    protocolNames: ["AudioRecordingIntent"],
                    parameters: [],
                    returnsValue: true
                )
            ],
            shortcutsProviders: [
                ScannedShortcutsProvider(
                    typeName: "iMoonshineShortcuts",
                    kind: .struct,
                    shortcuts: [
                        ScannedShortcut(
                            intentTypeName: "ToggleRecordingIntent",
                            phrases: ["Toggle \\(.applicationName)"],
                            shortTitle: "iMoonshine Toggle",
                            systemImageName: "mic.circle.fill"
                        )
                    ]
                )
            ]
        )

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputDir = dir.appendingPathComponent("Metadata.appintents")
        try Emitter().emit(module: module, inputs: makeInputs(), outputDir: outputDir)

        let actionsURL = outputDir.appendingPathComponent("extract.actionsdata")
        let versionURL = outputDir.appendingPathComponent("version.json")
        #expect(FileManager.default.fileExists(atPath: actionsURL.path))
        #expect(FileManager.default.fileExists(atPath: versionURL.path))

        // No nlu.appintents — phrases live inside extract.actionsdata.autoShortcuts now.
        let lprojDir = outputDir.appendingPathComponent("en.lproj")
        #expect(!FileManager.default.fileExists(atPath: lprojDir.path))

        let actionsData = try Data(contentsOf: actionsURL)
        guard let json = try JSONSerialization.jsonObject(with: actionsData) as? [String: Any] else {
            Issue.record("extract.actionsdata is not JSON")
            return
        }
        // Top-level keys we promise.
        let expectedTopKeys: Set<String> = [
            "version", "generator", "shortcutTileColor", "actions", "entities",
            "enums", "queries", "autoShortcuts", "autoShortcutProviderMangledName",
            "negativePhrases", "assistantEntities", "assistantIntents",
            "assistantIntentNegativePhrases",
        ]
        #expect(expectedTopKeys.isSubset(of: Set(json.keys)))

        let actions = json["actions"] as? [String: Any] ?? [:]
        #expect(actions.keys.contains("ToggleRecordingIntent"))
        guard let action = actions["ToggleRecordingIntent"] as? [String: Any] else {
            Issue.record("action entry missing")
            return
        }
        #expect(action["fullyQualifiedTypeName"] as? String == "iMoonshine.ToggleRecordingIntent")
        #expect(action["mangledTypeName"] as? String == "10iMoonshine21ToggleRecordingIntentV")
        #expect(action["outputFlags"] as? Int == 4) // ReturnsValue
        let outputType = action["outputType"] as? [String: Any]
        let primitive = outputType?["primitive"] as? [String: Any]
        let wrapper = primitive?["wrapper"] as? [String: Any]
        #expect(wrapper?["typeIdentifier"] as? Int == 0)
        #expect(action["openAppWhenRun"] as? Bool == false)
        #expect(action["isDiscoverable"] as? Bool == true)
        #expect((action["title"] as? [String: Any])?["key"] as? String == "Toggle iMoonshine")

        let protocols = action["systemProtocols"] as? [String] ?? []
        #expect(protocols.contains("com.apple.link.systemProtocol.AudioRecording"))
        #expect(protocols.contains("com.apple.link.systemProtocol.SessionStarting"))

        let visibility = action["visibilityMetadata"] as? [String: Any] ?? [:]
        #expect(visibility["isDiscoverable"] as? Bool == true)
        #expect(visibility["assistantOnly"] as? Bool == false)

        // autoShortcuts surface the phrase templates.
        let autoShortcuts = json["autoShortcuts"] as? [[String: Any]] ?? []
        #expect(autoShortcuts.count == 1)
        let firstShortcut = autoShortcuts.first ?? [:]
        #expect(firstShortcut["actionIdentifier"] as? String == "ToggleRecordingIntent")
        #expect(firstShortcut["systemImageName"] as? String == "mic.circle.fill")
        let templates = firstShortcut["phraseTemplates"] as? [[String: Any]] ?? []
        #expect(templates.first?["key"] as? String == "Toggle ${applicationName}")

        let providerMangled = json["autoShortcutProviderMangledName"] as? String
        #expect(providerMangled == "10iMoonshine19iMoonshineShortcutsV")

        // version.json shape matches Apple's `{ toolsVersion, version }`.
        let versionData = try Data(contentsOf: versionURL)
        let version = try JSONSerialization.jsonObject(with: versionData) as? [String: Any] ?? [:]
        #expect(version["version"] as? String == "3.0")
        #expect(version["toolsVersion"] as? String == "swift-6.3.1")
    }

    @Test("App-extension intents report supportedModes=2 (except AudioRecordingIntent)")
    func appExtensionSupportedModes() throws {
        let module = ScannedModule(
            intents: [
                ScannedIntent(
                    typeName: "WidgetConfig",
                    kind: .struct,
                    isDiscoverable: true,
                    protocolNames: ["WidgetConfigurationIntent"],
                    parameters: [],
                    returnsValue: false
                ),
                ScannedIntent(
                    typeName: "AudioIntent",
                    kind: .struct,
                    isDiscoverable: true,
                    protocolNames: ["AudioRecordingIntent"],
                    parameters: [],
                    returnsValue: false
                )
            ]
        )
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputDir = dir.appendingPathComponent("Metadata.appintents")
        try Emitter().emit(module: module, inputs: makeInputs(isAppExtension: true), outputDir: outputDir)

        let actionsData = try Data(contentsOf: outputDir.appendingPathComponent("extract.actionsdata"))
        let json = try JSONSerialization.jsonObject(with: actionsData) as? [String: Any] ?? [:]
        let actions = json["actions"] as? [String: Any] ?? [:]
        let widgetAction = actions["WidgetConfig"] as? [String: Any] ?? [:]
        #expect(widgetAction["supportedModes"] as? Int == 2)
        #expect(widgetAction["outputFlags"] as? Int == 0)
        #expect(!widgetAction.keys.contains("outputType"))

        let audioAction = actions["AudioIntent"] as? [String: Any] ?? [:]
        #expect(audioAction["supportedModes"] as? Int == 1)
        #expect(!audioAction.keys.contains("outputType"))
    }

    @Test("Provider declared in a different module mangles with that module's name")
    func crossModuleProviderMangledName() throws {
        // iMoonshine layout: host product is `iMoonshine`; both the
        // `iMoonshineShortcuts` provider and `ToggleRecordingIntent` live in
        // the shared `iMoonshineCore` library target. The emitter must use
        // `iMoonshineCore` for the mangled names, not the host module.
        let module = ScannedModule(
            intents: [
                ScannedIntent(
                    typeName: "ToggleRecordingIntent",
                    kind: .struct,
                    module: "iMoonshineCore",
                    isDiscoverable: true,
                    protocolNames: ["AudioRecordingIntent"],
                    returnsValue: true
                )
            ],
            shortcutsProviders: [
                ScannedShortcutsProvider(
                    typeName: "iMoonshineShortcuts",
                    kind: .struct,
                    module: "iMoonshineCore",
                    shortcuts: [
                        ScannedShortcut(
                            intentTypeName: "ToggleRecordingIntent",
                            phrases: ["Toggle iMoonshine"]
                        )
                    ]
                )
            ]
        )
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputDir = dir.appendingPathComponent("Metadata.appintents")
        try Emitter().emit(module: module, inputs: makeInputs(), outputDir: outputDir)

        let data = try Data(contentsOf: outputDir.appendingPathComponent("extract.actionsdata"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        #expect(json["autoShortcutProviderMangledName"] as? String
                == "14iMoonshineCore19iMoonshineShortcutsV")

        let actions = json["actions"] as? [String: Any] ?? [:]
        let action = actions["ToggleRecordingIntent"] as? [String: Any] ?? [:]
        #expect(action["fullyQualifiedTypeName"] as? String
                == "iMoonshineCore.ToggleRecordingIntent")
        #expect(action["mangledTypeName"] as? String
                == "14iMoonshineCore21ToggleRecordingIntentV")
    }

    @Test("Emits 'packages' array for AppIntentsPackage declarations")
    func emitsPackages() throws {
        let module = ScannedModule(
            packages: [
                ScannedPackage(typeName: "iMoonshineIntentsPackage", kind: .struct, module: "iMoonshineCore")
            ]
        )
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputDir = dir.appendingPathComponent("Metadata.appintents")
        try Emitter().emit(module: module, inputs: makeInputs(), outputDir: outputDir)

        let actionsData = try Data(contentsOf: outputDir.appendingPathComponent("extract.actionsdata"))
        let json = try JSONSerialization.jsonObject(with: actionsData) as? [String: Any] ?? [:]
        let packages = json["packages"] as? [[String: Any]] ?? []
        #expect(packages.count == 1)
        #expect(packages[0]["identifier"] as? String == "iMoonshineIntentsPackage")
        #expect(packages[0]["mangledTypeName"] as? String == "14iMoonshineCore24iMoonshineIntentsPackageV")
    }

    @Test("Skips writing the bundle when there are no AppIntents")
    func emptyModule() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputDir = dir.appendingPathComponent("Metadata.appintents")
        let module = try Generator().generate(
            sourceRoots: [],
            inputs: makeInputs(),
            outputDir: outputDir
        )
        #expect(module.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: outputDir.path))
    }
}

@Suite("MangledName") struct MangledNameTests {

    @Test("Encodes top-level Swift types with the lightweight Apple grammar")
    func encodesTopLevelTypes() {
        // Reference fixtures from Wispr Flow 1.55:
        //   Flow.StartStopRecordingAppIntent (struct) -> 4Flow27StartStopRecordingAppIntentV
        //   Widgets.NoteAppIntent (struct)            -> 7Widgets13NoteAppIntentV
        //   Flow.ShortcutsProvider (struct)           -> 4Flow17ShortcutsProviderV
        #expect(MangledName.encode(module: "Flow", typeName: "StartStopRecordingAppIntent", kind: .struct)
                == "4Flow27StartStopRecordingAppIntentV")
        #expect(MangledName.encode(module: "Widgets", typeName: "NoteAppIntent", kind: .struct)
                == "7Widgets13NoteAppIntentV")
        #expect(MangledName.encode(module: "Flow", typeName: "ShortcutsProvider", kind: .struct)
                == "4Flow17ShortcutsProviderV")
    }

    @Test("Picks the right kind suffix per declaration kind")
    func kindSuffix() {
        #expect(MangledName.encode(module: "M", typeName: "T", kind: .struct).last == "V")
        #expect(MangledName.encode(module: "M", typeName: "T", kind: .class).last == "C")
        #expect(MangledName.encode(module: "M", typeName: "T", kind: .enum).last == "O")
    }
}

@Suite("SystemProtocols") struct SystemProtocolsTests {

    @Test("AudioRecordingIntent maps to the confirmed pair of reverse-DNS protocols")
    func audioRecording() {
        let resolved = SystemProtocols.resolve(for: ["AudioRecordingIntent"])
        #expect(resolved == [
            "com.apple.link.systemProtocol.SessionStarting",
            "com.apple.link.systemProtocol.AudioRecording",
        ])
    }

    @Test("Plain AppIntent has no system protocols")
    func plainAppIntent() {
        #expect(SystemProtocols.resolve(for: ["AppIntent"]).isEmpty)
    }

    @Test("De-duplicates across multiple conformances")
    func dedup() {
        let resolved = SystemProtocols.resolve(for: ["AudioRecordingIntent", "AudioRecordingIntent"])
        #expect(resolved.count == 2)
    }

    @Test("Module-qualified protocol names match by trailing identifier")
    func moduleQualified() {
        let resolved = SystemProtocols.resolve(for: ["AppIntents.AudioRecordingIntent"])
        #expect(resolved.contains("com.apple.link.systemProtocol.AudioRecording"))
    }
}
