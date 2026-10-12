import Foundation
import Testing
import Dependencies
import XToolSupport
@testable import XKit

/// Builds the contents of an `.ipa` on disk. The defaults describe a build that App Store Connect accepts.
private struct IPAFixture {
    var payloadApps = ["App.app"]
    var infoPlist: [String: Any]? = [
        "CFBundleIdentifier": "com.example.App",
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "45",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconName": "AppIcon"]],
        "BuildMachineOSBuild": "25G83",
        "DTCompiler": "com.apple.compilers.llvm.clang.1_0",
        "DTPlatformBuild": "23F73",
        "DTPlatformName": "iphoneos",
        "DTPlatformVersion": "26.5",
        "DTSDKBuild": "23F73",
        "DTSDKName": "iphoneos26.5",
        "DTXcode": "2650",
        "DTXcodeBuild": "17F42",
    ]
    var hasAssetCatalog = true
    var profile: [String: Any]? = [
        "Name": "App Store",
        "Entitlements": [
            "application-identifier": "TEAM123456.com.example.App",
            "get-task-allow": false,
        ],
    ]

    /// Writes the fixture under a new temporary directory, which the caller removes.
    func write() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPAInspectorTests-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        for name in payloadApps {
            let app = root.appendingPathComponent("Payload/\(name)", isDirectory: true)
            try fileManager.createDirectory(at: app, withIntermediateDirectories: true)
            // only the first app is described, the others only need to exist
            guard name == payloadApps[0] else { continue }
            if let infoPlist {
                try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .binary, options: 0)
                    .write(to: app.appendingPathComponent("Info.plist"))
            }
            if hasAssetCatalog {
                try Data("car".utf8).write(to: app.appendingPathComponent("Assets.car"))
            }
            if let profile {
                // the real thing is a CMS envelope around the plist
                var data = Data([0x30, 0x82, 0x01, 0x00, 0x06, 0x09])
                data += try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
                data += Data([0x31, 0x82, 0x02, 0x00])
                try data.write(to: app.appendingPathComponent("embedded.mobileprovision"))
            }
        }
        return root
    }

    func report() throws -> IPAReport {
        let root = try write()
        defer { try? FileManager.default.removeItem(at: root) }
        return IPAInspector.inspect(extracted: root)
    }
}

private func messages(_ findings: [IPAFinding]) -> String {
    findings.map(\.message).joined(separator: "\n")
}

@Suite struct IPAInspectorTests {
    @Test func acceptsABuildThatLooksLikeXcode() throws {
        let report = try IPAFixture().report()
        #expect(report.findings.isEmpty)
        #expect(report.info == IPAInfo(
            bundleID: "com.example.App", version: "1.2.3", build: "45", platform: "IOS"
        ))
    }

    @Test func warnsAboutKeysThatXcodeStamps() throws {
        var fixture = IPAFixture()
        fixture.infoPlist?["DTXcode"] = nil
        fixture.infoPlist?["DTSDKBuild"] = nil
        let report = try fixture.report()

        #expect(report.errors.isEmpty)
        let warning = try #require(report.warnings.first)
        #expect(report.warnings.count == 1)
        #expect(warning.message.contains("DTSDKBuild, DTXcode"))
        // it's still uploadable
        #expect(report.info != nil)
    }

    @Test func readsThePlatform() throws {
        var fixture = IPAFixture()
        fixture.infoPlist?["CFBundleSupportedPlatforms"] = ["XROS"]
        #expect(try fixture.report().info?.platform == "VISION_OS")
    }

    @Test(arguments: [
        ("CFBundleIdentifier", "CFBundleIdentifier"),
        ("CFBundleShortVersionString", "CFBundleShortVersionString"),
        ("CFBundleVersion", "CFBundleVersion"),
    ])
    func requiresTheKeysThatIdentifyTheBuild(key: String, expected: String) throws {
        var fixture = IPAFixture()
        fixture.infoPlist?[key] = nil
        let report = try fixture.report()

        #expect(report.info == nil)
        #expect(messages(report.errors).contains("no \(expected)"))
    }

    @Test func requiresExactlyOneApp() throws {
        var none = IPAFixture()
        none.payloadApps = []
        let noneReport = try none.report()
        #expect(noneReport.info == nil)
        #expect(messages(noneReport.errors).contains("no Payload"))

        var several = IPAFixture()
        several.payloadApps = ["A.app", "B.app"]
        let severalReport = try several.report()
        #expect(severalReport.info == nil)
        #expect(messages(severalReport.errors).contains("exactly one .app"))
    }

    @Test func requiresAReadableInfoPlist() throws {
        var fixture = IPAFixture()
        fixture.infoPlist = nil
        let report = try fixture.report()
        #expect(report.info == nil)
        #expect(messages(report.errors).contains("Info.plist is missing"))
    }

    @Test func requiresACompiledIcon() throws {
        var noCatalog = IPAFixture()
        noCatalog.hasAssetCatalog = false
        #expect(messages(try noCatalog.report().errors).contains("Assets.car"))

        var noName = IPAFixture()
        noName.infoPlist?["CFBundleIcons"] = nil
        noName.infoPlist?["CFBundleIconFile"] = "icon.png"
        #expect(messages(try noName.report().errors).contains("CFBundleIconName"))

        // the name may also be on the iPad key, or at the top level
        var ipad = IPAFixture()
        ipad.infoPlist?["CFBundleIcons"] = nil
        ipad.infoPlist?["CFBundleIcons~ipad"] = ["CFBundlePrimaryIcon": ["CFBundleIconName": "AppIcon"]]
        #expect(try ipad.report().errors.isEmpty)
        var topLevel = IPAFixture()
        topLevel.infoPlist?["CFBundleIcons"] = nil
        topLevel.infoPlist?["CFBundleIconName"] = "AppIcon"
        #expect(try topLevel.report().errors.isEmpty)
    }

    @Test func requiresAnAppStoreProfile() throws {
        var missing = IPAFixture()
        missing.profile = nil
        #expect(messages(try missing.report().errors).contains("no embedded.mobileprovision"))

        var development = IPAFixture()
        development.profile = [
            "ProvisionedDevices": ["00008030-000000000000802E"],
            "Entitlements": ["application-identifier": "TEAM123456.com.example.App", "get-task-allow": true],
        ]
        let developmentErrors = messages(try development.report().errors)
        #expect(developmentErrors.contains("development, ad-hoc or enterprise"))
        #expect(developmentErrors.contains("get-task-allow"))

        var enterprise = IPAFixture()
        enterprise.profile = [
            "ProvisionsAllDevices": true,
            "Entitlements": ["application-identifier": "TEAM123456.com.example.App", "get-task-allow": false],
        ]
        #expect(messages(try enterprise.report().errors).contains("enterprise"))
    }

    @Test func checksTheProfileMatchesTheBundleID() throws {
        var other = IPAFixture()
        other.profile = ["Entitlements": [
            "application-identifier": "TEAM123456.com.example.Other", "get-task-allow": false,
        ]]
        #expect(messages(try other.report().errors).contains("not for the bundle ID com.example.App"))

        for wildcard in ["TEAM123456.*", "TEAM123456.com.example.*"] {
            var fixture = IPAFixture()
            fixture.profile = ["Entitlements": ["application-identifier": wildcard, "get-task-allow": false]]
            #expect(try fixture.report().errors.isEmpty, "\(wildcard)")
        }
    }

    @Test func inspectsAZippedIPA() async throws {
        let root = try IPAFixture().write()
        defer { try? FileManager.default.removeItem(at: root) }
        let ipa = root.appendingPathComponent("App.ipa")

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        zip.arguments = ["zip", "-qr", ipa.path, "Payload"]
        zip.currentDirectoryURL = root
        try zip.run()
        zip.waitUntilExit()
        try #require(zip.terminationStatus == 0)

        let report = try await withDependencies {
            $0.zipCompressor = .liveValue
        } operation: {
            try await IPAInspector().inspect(ipa: ipa)
        }
        #expect(report.findings.isEmpty)
        #expect(report.info?.bundleID == "com.example.App")
    }
}
