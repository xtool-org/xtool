import Foundation
import Testing
@testable import PackLib

private func literal(_ label: String, _ value: String) -> JSONValue {
    ["label": .string(label), "type": "Swift.String", "valueKind": "RawLiteral", "value": .string(value)]
}

private func intent(
    _ name: String,
    conformances: [String] = [],
    properties: [JSONValue],
    result: [String] = ["AppIntents.IntentResult"]
) -> JSONValue {
    [
        "typeName": .string(name),
        "mangledTypeName": .string("mangled\(name)"),
        "kind": "struct",
        "file": "Intents.swift",
        "line": 1,
        "conformances": .array((["AppIntents.AppIntent", "Swift.Sendable"] + conformances).map(JSONValue.string)),
        "allConformances": [],
        "associatedTypeAliases": [
            [
                "typeAliasName": "PerformResult",
                "opaqueTypeProtocolRequirements": .array(result.map(JSONValue.string)),
            ],
        ],
        "properties": .array(properties),
    ]
}

private let shortcuts: JSONValue = [
    "typeName": "App.Shortcuts",
    "mangledTypeName": "mangledShortcuts",
    "kind": "struct",
    "file": "Shortcuts.swift",
    "line": 1,
    "conformances": ["AppIntents.AppShortcutsProvider"],
    "properties": [
        [
            "label": "appShortcuts",
            "valueKind": "Builder",
            "value": [
                "members": [
                    [
                        "kind": "buildExpression",
                        "element": [
                            "valueKind": "InitCall",
                            "value": [
                                "arguments": [
                                    ["label": "intent", "type": "Shared.StopIntent"],
                                    [
                                        "label": "phrases",
                                        "value": [
                                            [
                                                "valueKind": "InterpolatedStringLiteral",
                                                "value": [
                                                    "segments": [
                                                        ["valueKind": "RawLiteral", "value": "Stop "],
                                                        ["valueKind": "Enum", "value": ["name": "applicationName"]],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                    ["label": "shortTitle", "valueKind": "RawLiteral", "value": "stop.short"],
                                    ["label": "systemImageName", "valueKind": "RawLiteral", "value": "stop.fill"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ],
    ],
]

private func decode(_ files: [String: Data]?) throws -> JSONValue {
    let data = try #require(files?["extract.actionsdata"])
    return try JSONDecoder().decode(JSONValue.self, from: data)
}

@Test func appIntentsMetadataIndexesIntentsAndShortcuts() throws {
    let entries = [
        intent(
            "Shared.StopIntent",
            conformances: ["AppIntents.LiveActivityIntent"],
            properties: [literal("title", "stop.title"), literal("description", "stop.description")]
        ),
        intent(
            "App.OpenIntent",
            properties: [literal("title", "open.title"), literal("openAppWhenRun", "true")],
            result: ["AppIntents.IntentResult", "AppIntents.ProvidesDialog"]
        ),
        shortcuts,
        // types that don't involve App Intents are ignored
        ["typeName": "App.Other", "conformances": ["Swift.Sendable"], "availability": []],
    ]
    let files = try AppIntentsMetadata(
        entries: entries,
        sharedBundleIDs: ["Shared": ["com.example.app", "com.example.app.widget"]]
    ).files()
    #expect(files?["version.json"].map { String(decoding: $0, as: UTF8.self) }?.contains("\"17F113\"") == true)

    let metadata = try decode(files)
    #expect(metadata["autoShortcutProviderMangledName"] == "mangledShortcuts")

    let stop = try #require(metadata["actions"]?["StopIntent"])
    #expect(stop["title"] == ["alternatives": [], "key": "stop.title"])
    #expect(stop["descriptionMetadata"]?["descriptionText"]?["key"] == "stop.description")
    #expect(stop["systemProtocols"] == ["com.apple.link.systemProtocol.SessionStarting"])
    #expect(stop["systemProtocolMetadata"] == ["com.apple.link.systemProtocol.SessionStarting", ["empty": [:]]])
    #expect(stop["supportedModes"] == 1)
    #expect(stop["openAppWhenRun"] == false)
    #expect(stop["mangledTypeNameByBundleIdentifier"] == [
        "com.example.app": "mangledShared.StopIntent",
        "com.example.app.widget": "mangledShared.StopIntent",
    ])

    let open = try #require(metadata["actions"]?["OpenIntent"])
    #expect(open["supportedModes"] == 2)
    #expect(open["outputFlags"] == 4)
    #expect(open["mangledTypeNameByBundleIdentifier"]?.object?.isEmpty == true)
    #expect(open["descriptionMetadata"] == nil)

    #expect(metadata["autoShortcuts"] == [
        [
            "actionIdentifier": "StopIntent",
            "availabilityAnnotations": ["LNPlatformNameWildcard": ["introducedVersion": "*"]],
            "phraseTemplates": [["alternatives": [], "key": "Stop ${applicationName}"]],
            "shortTitle": ["alternatives": [], "key": "stop.short"],
            "systemImageName": "stop.fill",
        ],
    ])
}

@Test func appIntentsMetadataIsLeftOutWithoutIntents() throws {
    let entries: [JSONValue] = [["typeName": "App.Other", "conformances": ["SwiftUI.App"]]]
    #expect(try AppIntentsMetadata(entries: entries, sharedBundleIDs: [:]).files() == nil)
}

@Test func appIntentsMetadataRefusesWhatItCannotIndex() {
    let parameter: JSONValue = ["label": "_name", "propertyWrappers": [], "valueKind": "Runtime"]
    let cases: [JSONValue] = [
        intent("App.ParamIntent", properties: [literal("title", "t"), parameter]),
        intent("App.NoTitleIntent", properties: []),
        intent("App.ComputedTitleIntent", properties: [["label": "title", "valueKind": "Runtime"]]),
        intent("App.EntityIntent", conformances: ["AppIntents.ForegroundContinuableIntent"], properties: [literal("title", "t")]),
        ["typeName": "App.Entity", "conformances": ["AppIntents.AppEntity"]],
    ]
    for entry in cases {
        #expect(throws: AppIntentsMetadata.Unsupported.self) {
            try AppIntentsMetadata(entries: [entry], sharedBundleIDs: [:]).files()
        }
    }
}
