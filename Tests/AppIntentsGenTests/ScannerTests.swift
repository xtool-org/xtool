import Foundation
import Testing

@testable import AppIntentsGen

@Suite("Scanner") struct ScannerTests {

    @Test("Recognises a basic AppIntent with parameters")
    func basicAppIntent() {
        let source = """
        import AppIntents

        struct ToggleRecordingIntent: AppIntent {
            static let title: LocalizedStringResource = "Toggle iMoonshine"
            static let description = IntentDescription("Start or stop recording.", categoryName: "iMoonshine")
            static let openAppWhenRun: Bool = false
            static let isDiscoverable: Bool = true

            @Parameter(title: "Loud", description: "Whether to be loud") var loud: Bool
            @Parameter(title: "Note") var note: String?

            func perform() async throws -> some IntentResult & ReturnsValue<String> {
                .result(value: "")
            }
        }
        """
        let module = Scanner().scan(source: source)
        #expect(module.intents.count == 1)
        let intent = module.intents[0]
        #expect(intent.typeName == "ToggleRecordingIntent")
        #expect(intent.title == "Toggle iMoonshine")
        #expect(intent.descriptionText == "Start or stop recording.")
        #expect(intent.categoryName == "iMoonshine")
        #expect(intent.openAppWhenRun == false)
        #expect(intent.isDiscoverable == true)
        #expect(intent.returnsValue == true)
        #expect(intent.parameters.count == 2)
        #expect(intent.parameters[0].propertyName == "loud")
        #expect(intent.parameters[0].typeName == "Bool")
        #expect(intent.parameters[0].title == "Loud")
        #expect(intent.parameters[0].descriptionText == "Whether to be loud")
        #expect(intent.parameters[0].isOptional == false)
        #expect(intent.parameters[1].propertyName == "note")
        #expect(intent.parameters[1].typeName == "String?")
        #expect(intent.parameters[1].isOptional == true)
    }

    @Test("Picks up AppShortcutsProvider phrases inside a result-builder body")
    func shortcutsProvider() {
        let source = """
        import AppIntents

        struct iMoonshineShortcuts: AppShortcutsProvider {
            static var appShortcuts: [AppShortcut] {
                AppShortcut(
                    intent: ToggleRecordingIntent(),
                    phrases: [
                        "Toggle \\(.applicationName)",
                        "Start \\(.applicationName) recording",
                        "Stop \\(.applicationName) recording"
                    ],
                    shortTitle: "iMoonshine Toggle",
                    systemImageName: "mic.circle.fill"
                )
            }
        }
        """
        let module = Scanner().scan(source: source)
        #expect(module.shortcutsProviders.count == 1)
        let provider = module.shortcutsProviders[0]
        #expect(provider.typeName == "iMoonshineShortcuts")
        #expect(provider.shortcuts.count == 1)
        let shortcut = provider.shortcuts[0]
        #expect(shortcut.intentTypeName == "ToggleRecordingIntent")
        #expect(shortcut.shortTitle == "iMoonshine Toggle")
        #expect(shortcut.systemImageName == "mic.circle.fill")
        #expect(shortcut.phrases.count == 3)
        #expect(shortcut.phrases[0] == "Toggle \\(.applicationName)")
    }

    @Test("Returns an empty module when no AppIntents are present")
    func emptyModule() {
        let source = """
        import Foundation

        struct PlainOldStruct {
            var x: Int = 0
        }
        """
        let module = Scanner().scan(source: source)
        #expect(module.isEmpty)
    }

    @Test("Stamps the active module name onto each scanned declaration")
    func moduleAttribution() {
        let intentSource = """
        import AppIntents

        struct ToggleRecordingIntent: AppIntent {
            static let title: LocalizedStringResource = "Toggle"
            func perform() async throws -> some IntentResult { .result() }
        }

        struct iMoonshineShortcuts: AppShortcutsProvider {
            static var appShortcuts: [AppShortcut] {
                AppShortcut(intent: ToggleRecordingIntent(), phrases: ["Toggle"])
            }
        }
        """
        let hostSource = """
        import AppIntents
        struct OpenAppIntent: AppIntent {
            static let title: LocalizedStringResource = "Open"
            func perform() async throws -> some IntentResult { .result() }
        }
        """
        var module = Scanner().scan(source: intentSource, module: "iMoonshineCore")
        module.merge(Scanner().scan(source: hostSource, module: "iMoonshine"))

        let providerModules = module.shortcutsProviders.map(\.module)
        #expect(providerModules == ["iMoonshineCore"])

        let intentByName = Dictionary(uniqueKeysWithValues: module.intents.map { ($0.typeName, $0) })
        #expect(intentByName["ToggleRecordingIntent"]?.module == "iMoonshineCore")
        #expect(intentByName["OpenAppIntent"]?.module == "iMoonshine")
    }

    @Test("returnsValue=false when perform() returns plain IntentResult without ReturnsValue")
    func returnsValueRequiresReturnsValueProtocol() {
        let source = """
        import AppIntents

        struct VoidIntent: AppIntent {
            static let title: LocalizedStringResource = "Void"
            func perform() async throws -> some IntentResult { .result() }
        }
        """
        let module = Scanner().scan(source: source)
        #expect(module.intents.count == 1)
        #expect(module.intents[0].returnsValue == false)
    }

    @Test("returnsValue=true when ReturnsValue appears anywhere in composition")
    func returnsValueDetectedInComposition() {
        let source = """
        import AppIntents

        struct A: AppIntent {
            static let title: LocalizedStringResource = "A"
            func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
                .result(value: "x", dialog: "ok")
            }
        }

        struct B: AppIntent {
            static let title: LocalizedStringResource = "B"
            func perform() async throws -> ReturnsValue<Int> { fatalError() }
        }

        struct C: AppIntent {
            static let title: LocalizedStringResource = "C"
            func perform() async throws -> AppIntents.ReturnsValue<String> { fatalError() }
        }
        """
        let module = Scanner().scan(source: source)
        let byName = Dictionary(uniqueKeysWithValues: module.intents.map { ($0.typeName, $0) })
        #expect(byName["A"]?.returnsValue == true)
        #expect(byName["B"]?.returnsValue == true)
        #expect(byName["C"]?.returnsValue == true)
    }

    @Test("returnsValue=false when perform() has no return clause")
    func returnsValueFalseWhenNoReturnClause() {
        let source = """
        import AppIntents

        struct NoReturn: AppIntent {
            static let title: LocalizedStringResource = "NR"
            func perform() async throws { }
        }
        """
        let module = Scanner().scan(source: source)
        #expect(module.intents.first?.returnsValue == false)
    }

    @Test("Captures AppEntity and AppEnum declarations")
    func entitiesAndEnums() {
        let source = """
        import AppIntents

        struct Note: AppEntity {
            static var typeDisplayRepresentation: TypeDisplayRepresentation { .init(name: "Note") }
            var displayRepresentation: DisplayRepresentation { .init(title: "x") }
            static var defaultQuery = NoteQuery()
            var id: String
        }

        enum Mood: String, AppEnum {
            case happy
            case sad
            static var typeDisplayRepresentation: TypeDisplayRepresentation { .init(name: "Mood") }
            static var caseDisplayRepresentations: [Mood: DisplayRepresentation] { [:] }
        }
        """
        let module = Scanner().scan(source: source)
        #expect(module.entities.count == 1)
        #expect(module.entities[0].typeName == "Note")
        #expect(module.enums.count == 1)
        #expect(module.enums[0].typeName == "Mood")
        #expect(module.enums[0].cases == ["happy", "sad"])
    }
}
