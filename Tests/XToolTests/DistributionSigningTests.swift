import Foundation
import Testing
@testable import XKit

private func profile(_ data: Data) throws -> DistributionProfile {
    try DistributionProfile(data: data)
}

private func identity(_ p12: Data = SigningFixtures.distributionP12) throws -> DistributionIdentity {
    try DistributionIdentity(p12: p12, password: SigningFixtures.p12Password)
}

private func resolved(
    _ data: Data,
    bundleID: String = SigningFixtures.bundleID,
    requested: [String: Any]? = nil
) throws -> [String: Any] {
    let requested = try requested.map(DistributionEntitlements.entitlements(from:))
    return try DistributionEntitlements.dictionary(of: DistributionEntitlements.resolve(
        profile: profile(data), bundleID: bundleID, requested: requested
    ))
}

// MARK: - Profile parsing

@Suite struct DistributionProfileParsingTests {
    @Test func appStoreProfile() throws {
        let profile = try profile(SigningFixtures.appstoreProfile)
        #expect(profile.digest.kind == .appStore)
        #expect(profile.digest.devices.isEmpty)
        #expect(profile.digest.teamIdentifiers.map(\.rawValue) == [SigningFixtures.teamID])
        #expect(profile.digest.platforms == ["iOS"])
        #expect(profile.digest.expirationDate > Date())
        #expect(profile.digest.certificates.count == 1)
        #expect(profile.applicationIdentifier == "\(SigningFixtures.teamID).\(SigningFixtures.bundleID)")
        let entitlements = try DistributionEntitlements.dictionary(of: profile.digest.entitlements)
        #expect(entitlements["aps-environment"] as? String == "production")
    }

    @Test func adHocProfile() throws {
        let profile = try profile(SigningFixtures.adhocProfile)
        #expect(profile.digest.kind == .adHoc)
        #expect(profile.digest.devices.count == 1)
    }

    @Test func developmentProfile() throws {
        let profile = try profile(SigningFixtures.developmentProfile)
        #expect(profile.digest.kind == .development)
        #expect(profile.digest.devices.count == 1)
    }

    @Test func invalidProfile() {
        #expect(throws: (any Error).self) { try profile(Data("not a profile".utf8)) }
    }

    @Test func bundleIDMatching() throws {
        let exact = try profile(SigningFixtures.appstoreProfile)
        #expect(exact.matches(bundleID: SigningFixtures.bundleID))
        #expect(!exact.matches(bundleID: "\(SigningFixtures.bundleID).widget"))
        #expect(!exact.matches(bundleID: "com.example.other"))

        let wildcard = try profile(SigningFixtures.wildcardProfile)
        #expect(wildcard.matches(bundleID: SigningFixtures.bundleID))
        #expect(wildcard.matches(bundleID: "com.anything.else"))

        // an exact profile is preferred over a wildcard one
        let exactScore = try #require(exact.specificity(forBundleID: SigningFixtures.bundleID))
        let wildcardScore = try #require(wildcard.specificity(forBundleID: SigningFixtures.bundleID))
        #expect(exactScore > wildcardScore)
    }
}

// MARK: - Identity and profile validation

@Suite struct DistributionValidationTests {
    @Test func loadsDistributionIdentity() throws {
        let identity = try identity()
        #expect(try identity.certificate.teamID() == SigningFixtures.teamID)
        #expect(try identity.certificate.isDistribution())
        #expect(try identity.certificate.data() == SigningFixtures.distributionCertificate)
        #expect(String(decoding: identity.privateKey.data, as: UTF8.self).hasPrefix("-----BEGIN PRIVATE KEY-----"))
        try identity.validate()
    }

    @Test func wrongP12Password() {
        #expect(throws: DistributionSigningError.wrongP12Password) {
            try DistributionIdentity(p12: SigningFixtures.distributionP12, password: "nope")
        }
    }

    @Test func invalidP12() {
        #expect(throws: DistributionSigningError.invalidP12) {
            try DistributionIdentity(p12: Data("garbage".utf8), password: "")
        }
        #expect(throws: DistributionSigningError.invalidP12) {
            try DistributionIdentity(p12: Data(), password: "")
        }
    }

    @Test func rejectsDevelopmentCertificate() throws {
        let identity = try identity(SigningFixtures.developmentP12)
        #expect(throws: DistributionSigningError.self) { try identity.validate() }
    }

    @Test func rejectsExpiredCertificate() throws {
        let identity = try identity()
        let future = identity.certificate.expirationDate.addingTimeInterval(1)
        #expect(throws: DistributionSigningError.self) { try identity.validate(now: future) }
    }

    @Test func acceptsAppStoreAndAdHocProfiles() throws {
        let identity = try identity()
        try profile(SigningFixtures.appstoreProfile).validate(for: identity)
        try profile(SigningFixtures.adhocProfile).validate(for: identity)
    }

    @Test func rejectsDevelopmentProfile() throws {
        let identity = try identity()
        let development = try profile(SigningFixtures.developmentProfile)
        #expect(throws: DistributionSigningError.notADistributionProfile(profile: development.name)) {
            try development.validate(for: identity)
        }
    }

    @Test func rejectsExpiredProfile() throws {
        let identity = try identity()
        let expired = try profile(SigningFixtures.expiredProfile)
        #expect(throws: DistributionSigningError.profileExpired(
            profile: expired.name, expired.digest.expirationDate
        )) {
            try expired.validate(for: identity)
        }
    }

    @Test func rejectsTeamMismatch() throws {
        let identity = try identity()
        let otherTeam = try profile(SigningFixtures.otherteamProfile)
        #expect(throws: DistributionSigningError.profileTeamMismatch(
            profile: otherTeam.name, certificateTeam: SigningFixtures.teamID, profileTeams: ["OTHERTEAM1"]
        )) {
            try otherTeam.validate(for: identity)
        }
    }

    @Test func rejectsProfileWithoutTheCertificate() throws {
        let identity = try identity()
        let otherCert = try profile(SigningFixtures.othercertProfile)
        #expect(throws: DistributionSigningError.self) { try otherCert.validate(for: identity) }
    }
}

// MARK: - Entitlements

@Suite struct DistributionEntitlementsTests {
    private let appID = "\(SigningFixtures.teamID).\(SigningFixtures.bundleID)"

    @Test func derivesEntitlementsFromTheProfile() throws {
        let ents = try resolved(SigningFixtures.appstoreProfile)
        #expect(ents["application-identifier"] as? String == appID)
        #expect(ents["com.apple.developer.team-identifier"] as? String == SigningFixtures.teamID)
        #expect(ents["aps-environment"] as? String == "production")
        #expect(ents["beta-reports-active"] as? Bool == true)
        #expect(ents["com.apple.security.application-groups"] as? [String] == ["group.com.example.app"])
        // `<team>.*` is narrowed to this app's group
        #expect(ents["keychain-access-groups"] as? [String] == [appID])
        // a lone wildcard can't be claimed as-is
        #expect(ents["com.apple.developer.associated-domains"] == nil)
    }

    @Test func getTaskAllowIsNeverTrue() throws {
        let profiles = [
            SigningFixtures.appstoreProfile, SigningFixtures.adhocProfile,
            SigningFixtures.wildcardProfile, SigningFixtures.developmentProfile,
        ]
        for data in profiles {
            #expect(try resolved(data)["get-task-allow"] as? Bool == false)
        }
        // even when the app (or a debug signature it came with) asks for it
        let ents = try resolved(SigningFixtures.appstoreProfile, requested: ["get-task-allow": true])
        #expect(ents["get-task-allow"] as? Bool == false)
    }

    @Test func wildcardProfileNamesTheActualApp() throws {
        let ents = try resolved(SigningFixtures.wildcardProfile)
        #expect(ents["application-identifier"] as? String == appID)
        #expect(ents["keychain-access-groups"] as? [String] == [appID])
    }

    @Test func adHocUsesTheProfilePushEnvironment() throws {
        let ents = try resolved(SigningFixtures.adhocProfile)
        #expect(ents["aps-environment"] as? String == "production")
        #expect(ents["beta-reports-active"] == nil)
    }

    @Test func projectEntitlementsNarrowWhatTheProfileGrants() throws {
        let ents = try resolved(SigningFixtures.appstoreProfile, requested: [
            "com.apple.developer.associated-domains": ["applinks:example.com"],
            "keychain-access-groups": ["\(SigningFixtures.teamID).shared"],
            "application-identifier": "stale.value",
        ])
        #expect(ents["com.apple.developer.associated-domains"] as? [String] == ["applinks:example.com"])
        #expect(ents["keychain-access-groups"] as? [String] == ["\(SigningFixtures.teamID).shared"])
        // identity keys always come from the profile
        #expect(ents["application-identifier"] as? String == appID)
        // like Xcode, we don't claim capabilities the app did not ask for...
        #expect(ents["aps-environment"] == nil)
        #expect(ents["com.apple.security.application-groups"] == nil)
        // ...except the ones the profile enables for every build
        #expect(ents["beta-reports-active"] as? Bool == true)
    }

    @Test func rejectsEntitlementsTheProfileDoesNotAllow() throws {
        #expect(throws: DistributionSigningError.self) {
            try resolved(SigningFixtures.appstoreProfile, requested: ["com.apple.developer.healthkit": true])
        }
        // a development push environment in a production profile
        #expect(throws: DistributionSigningError.self) {
            try resolved(SigningFixtures.appstoreProfile, requested: ["aps-environment": "development"])
        }
        // an app group the profile doesn't list
        #expect(throws: DistributionSigningError.self) {
            try resolved(SigningFixtures.appstoreProfile, requested: [
                "com.apple.security.application-groups": ["group.com.example.other"],
            ])
        }
    }
}

// MARK: - Signer preconditions

@Suite struct DistributionSignerTests {
    private func makeApp(extensions: [String] = []) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = root.appendingPathComponent("Test.app", isDirectory: true)
        func writeBundle(at url: URL, id: String) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "main"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Info.plist"))
        }
        try writeBundle(at: app, id: SigningFixtures.bundleID)
        for id in extensions {
            try writeBundle(at: app.appendingPathComponent("PlugIns/\(id).appex"), id: id)
        }
        return app
    }

    @Test func failsWithoutAMatchingProfile() async throws {
        let app = try makeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let signer = try DistributionSigner(
            identity: identity(),
            profiles: [profile(SigningFixtures.appextensionProfile)]
        )
        await #expect(throws: DistributionSigningError.noMatchingProfile(bundleID: SigningFixtures.bundleID)) {
            try await signer.sign(app: app)
        }
    }

    @Test func refusesDevelopmentProfiles() async throws {
        let app = try makeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let development = try profile(SigningFixtures.developmentProfile)
        let signer = try DistributionSigner(identity: identity(), profiles: [development])
        await #expect(throws: DistributionSigningError.notADistributionProfile(profile: development.name)) {
            try await signer.sign(app: app)
        }
        #expect(!app.appendingPathComponent("embedded.mobileprovision").exists)
    }

    @Test func signsEachBundleWithItsOwnProfileAndEntitlements() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try FakeApp.writeBundle(
            at: root.appendingPathComponent("Test.app"), id: SigningFixtures.bundleID
        )
        let widgetID = "\(SigningFixtures.bundleID).widget"
        let widget = try FakeApp.writeBundle(
            at: app.appendingPathComponent("PlugIns/Widget.appex"), id: widgetID
        )

        let signer = try DistributionSigner(
            identity: identity(),
            profiles: [profile(SigningFixtures.appstoreProfile), profile(SigningFixtures.appextensionProfile)]
        )
        let result = try await signer.sign(app: app)
        #expect(result.bundleID == SigningFixtures.bundleID)

        let appEnts = try #require(try FakeApp.entitlements(ofExecutable: app.appendingPathComponent("main")))
        let widgetEnts = try #require(try FakeApp.entitlements(ofExecutable: widget.appendingPathComponent("main")))
        let team = SigningFixtures.teamID
        #expect(appEnts["application-identifier"] as? String == "\(team).\(SigningFixtures.bundleID)")
        #expect(widgetEnts["application-identifier"] as? String == "\(team).\(widgetID)")
        #expect(appEnts["keychain-access-groups"] as? [String] == ["\(team).\(SigningFixtures.bundleID)"])
        #expect(widgetEnts["keychain-access-groups"] as? [String] == ["\(team).\(widgetID)"])
        for ents in [appEnts, widgetEnts] {
            #expect(ents["get-task-allow"] as? Bool == false)
            #expect(ents["aps-environment"] as? String == "production")
        }

        // each bundle carries the profile that matches it
        let appProfile = try Mobileprovision(contentsOf: app.appendingPathComponent("embedded.mobileprovision"))
        let widgetProfile = try Mobileprovision(contentsOf: widget.appendingPathComponent("embedded.mobileprovision"))
        #expect(try appProfile.data() == profile(SigningFixtures.appstoreProfile).mobileprovision.data())
        #expect(try widgetProfile.data() == profile(SigningFixtures.appextensionProfile).mobileprovision.data())
        #expect(app.appendingPathComponent("_CodeSignature/CodeResources").exists)

        // rewriting an executable to make room for the signature must not drop its permissions
        for bundle in [app, widget] {
            let attributes = try FileManager.default.attributesOfItem(atPath: bundle.appendingPathComponent("main").path)
            #expect((attributes[.posixPermissions] as? Int).map { $0 & 0o111 != 0 } == true)
        }
        #expect(widget.appendingPathComponent("_CodeSignature/CodeResources").exists)
    }
}
