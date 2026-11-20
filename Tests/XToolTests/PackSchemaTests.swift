import Foundation
import Testing
@testable import PackLib

@Test func packSchemaReportsUnknownTopLevelKeys() async throws {
    let error = await #expect(throws: StringError.self) {
        try await loadPackSchema("""
            version: 1
            orgID: com.example
            icon: App.png
            entitlements: App.entitlements
            """)
    }
    #expect(error?.description == #"xtool.yml: Unknown keys: "entitlements", "icon"."#)
}

@Test func packSchemaReportsUnknownExtensionKeysWithIndex() async throws {
    let error = await #expect(throws: StringError.self) {
        try await loadPackSchema("""
            version: 1
            orgID: com.example
            extensions:
              - product: Widget
                infoPath: Widget.plist
              - product: Share
                infoPath: Share.plist
                entitlements: Share.entitlements
            """)
    }
    #expect(error?.description == #"xtool.yml: Unknown key in extensions[1]: "entitlements"."#)
}

@Test func packSchemaAcceptsKnownKeysIncludingYAMLMerge() async throws {
    let schema = try await loadPackSchema("""
        version: 1
        <<: {orgID: com.example}
        iconPath: App.png
        extensions:
          - product: Widget
            infoPath: Widget.plist
            entitlementsPath: Widget.entitlements
        """)
    #expect(schema.orgID == "com.example")
    #expect(schema.iconPath == "App.png")
    #expect(schema.extensions?.first?.entitlementsPath == "Widget.entitlements")
}

private func loadPackSchema(_ yaml: String) async throws -> PackSchema {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).yml")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(yaml.utf8).write(to: url)
    return try await PackSchema(url: url)
}
