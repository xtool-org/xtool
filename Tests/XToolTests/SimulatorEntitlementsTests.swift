import Foundation
import Testing
@testable import PackLib

private let entitlementsPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>keychain-access-groups</key>
    <array>
        <string>com.example.shared</string>
    </array>
    <key>com.apple.developer.healthkit</key>
    <true/>
    <key>get-task-allow</key>
    <false/>
    <key>com.example.integer</key>
    <integer>300</integer>
    <key>com.example.one</key>
    <integer>1</integer>
    <key>com.example.negative</key>
    <integer>-1</integer>
    <key>com.example.nested</key>
    <dict>
        <key>b</key>
        <string>two</string>
        <key>a</key>
        <array/>
    </dict>
</dict>
</plist>
"""

@Test func entitlementsDERMatchesCodesign() throws {
    // from `codesign --sign - --entitlements <plist> --generate-entitlement-der`, extracted with `derq macho`
    let expected = bytes(hex: """
    7081e4020101b081de30220c1d636f6d2e6170706c652e646576656c6f7065722e6865616c74686b69740101ff30190c13636f6d2e
    6578616d706c652e696e74656765720202012c30190c14636f6d2e6578616d706c652e6e656761746976650201ff30270c12636f6d
    2e6578616d706c652e6e6573746564b01130050c0161300030080c01620c0374776f30140c0f636f6d2e6578616d706c652e6f6e65
    02010130130c0e6765742d7461736b2d616c6c6f77010100302e0c166b6579636861696e2d6163636573732d67726f75707330140c
    12636f6d2e6578616d706c652e736861726564
    """)
    #expect(try EntitlementsDER.encode(plist: Data(entitlementsPlist.utf8)) == expected)
}

@Test func simulatorBuildsLinkEntitlementsIn() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SimulatorEntitlementsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let entitlements = dir.appendingPathComponent("App.entitlements")
    try Data(entitlementsPlist.utf8).write(to: entitlements)
    let plan = Plan(
        app: Plan.Product(
            type: .application,
            product: "App",
            deploymentTarget: "17.0",
            bundleID: "com.example.App",
            infoPlist: [:],
            resources: [],
            iconPath: nil,
            entitlementsPath: entitlements.path
        ),
        extensions: []
    )

    let simulatorSettings = try await BuildSettings(
        configuration: .debug,
        triple: "arm64-apple-ios-simulator",
        buildSystem: .swiftPM
    )
    let flags = try await Packer(buildSettings: simulatorSettings, plan: plan).simulatorEntitlementsFlags(in: dir)
    let xml = dir.appendingPathComponent("App-App-Simulated.xcent")
    let der = dir.appendingPathComponent("App-App-Simulated.xcent.der")
    #expect(flags == ["App-App": [
        "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements", "-Xlinker", xml.path,
        "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__ents_der", "-Xlinker", der.path,
    ]])

    let original = try PropertyListSerialization.propertyList(from: Data(entitlementsPlist.utf8), format: nil)
    let written = try PropertyListSerialization.propertyList(from: Data(contentsOf: xml), format: nil)
    #expect((written as? NSDictionary) == (original as? NSDictionary))
    #expect(try Data(contentsOf: der) == EntitlementsDER.encode(plist: Data(entitlementsPlist.utf8)))

    let deviceSettings = try await BuildSettings(configuration: .debug, triple: "arm64-apple-ios", buildSystem: .swiftPM)
    #expect(try await Packer(buildSettings: deviceSettings, plan: plan).simulatorEntitlementsFlags(in: dir).isEmpty)
}

private func bytes(hex: String) -> Data {
    let digits = Array(hex.filter(\.isHexDigit))
    return Data(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
}
