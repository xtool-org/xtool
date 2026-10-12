import Foundation
import Testing
@testable import XKit

@Suite struct EntitlementsReconcilerTests {
    private func entitlements(_ dictionary: [String: Any]) throws -> Entitlements {
        try Entitlements(plistDictionary: dictionary)
    }

    private func reconcile(
        _ requested: [String: Any],
        granted: [String: Any]
    ) throws -> [String: Any] {
        try EntitlementsReconciler.reconcile(
            entitlements(requested), with: entitlements(granted), profileName: "dev profile"
        ).entitlements.plistDictionary()
    }

    /// What a development profile created through the ASC API grants an app with push but no groups
    private let developmentGrants: [String: Any] = [
        "application-identifier": "TEAM.XTL-1.app",
        "com.apple.developer.team-identifier": "TEAM",
        "get-task-allow": true,
        "aps-environment": "development",
        "com.apple.security.application-groups": [String](),
        "keychain-access-groups": ["TEAM.*"],
    ]

    @Test func pushEnvironmentComesFromTheProfile() throws {
        let result = try reconcile(
            ["aps-environment": "production", "get-task-allow": true], granted: developmentGrants
        )
        #expect(result["aps-environment"] as? String == "development")
        #expect(result["get-task-allow"] as? Bool == true)
    }

    @Test func appGroupsTheProfileLacksAreAnActionableError() throws {
        let error = try #require(throws: EntitlementsReconciler.Error.self) {
            try reconcile(
                ["com.apple.security.application-groups": ["group.com.example.app"]],
                granted: developmentGrants
            )
        }
        #expect(error == .appGroupsNotGranted(groups: ["group.com.example.app"], profile: "dev profile"))
        let message = try #require(error.errorDescription)
        #expect(message.contains("group.com.example.app"))
        #expect(message.contains("xtool auth login --mode password"))
        // what the CLI prints for `"\(error)"`
        #expect("\(error)" == message)
        #expect(String(describing: error as any Swift.Error) == message)
    }

    @Test func appGroupsAreKeptWhenTheProfileHasThem() throws {
        var granted = developmentGrants
        granted["com.apple.security.application-groups"] = ["group.XTL-1.example"]
        let result = try reconcile(
            ["com.apple.security.application-groups": ["group.XTL-1.example"]], granted: granted
        )
        #expect(result["com.apple.security.application-groups"] as? [String] == ["group.XTL-1.example"])
    }

    @Test func missingGrantNamesTheEntitlement() throws {
        let granted = developmentGrants.filter { $0.key != "aps-environment" }
        let error = try #require(throws: EntitlementsReconciler.Error.self) {
            try reconcile(["aps-environment": "development"], granted: granted)
        }
        #expect(error == .notGranted(key: "aps-environment", profile: "dev profile"))
    }

    @Test func onlyTheMissingGroupsAreReported() throws {
        var granted = developmentGrants
        granted["com.apple.security.application-groups"] = ["group.a"]
        #expect(throws: EntitlementsReconciler.Error.appGroupsNotGranted(groups: ["group.b"], profile: "dev profile")) {
            try reconcile(["com.apple.security.application-groups": ["group.a", "group.b"]], granted: granted)
        }
    }

    @Test func valueOutsideTheGrantIsRejected() throws {
        var granted = developmentGrants
        granted["com.apple.developer.networking.multipath"] = false
        #expect(throws: EntitlementsReconciler.Error.valueNotGranted(
            key: "com.apple.developer.networking.multipath", profile: "dev profile"
        )) {
            try reconcile(["com.apple.developer.networking.multipath": true], granted: granted)
        }
    }

    @Test func derivedAndUnknownEntitlementsAreLeftAlone() throws {
        let requested: [String: Any] = [
            "application-identifier": "TEAM.XTL-1.app",
            "keychain-access-groups": ["TEAM.XTL-1.app"],
            "com.example.not-a-capability-we-manage": true,
        ]
        let result = try reconcile(requested, granted: developmentGrants)
        #expect(result["application-identifier"] as? String == "TEAM.XTL-1.app")
        #expect(result["keychain-access-groups"] as? [String] == ["TEAM.XTL-1.app"])
        #expect(result["com.example.not-a-capability-we-manage"] as? Bool == true)
    }

    @Test func entitlementsWithoutIssuesAreUnchanged() throws {
        let requested: [String: Any] = ["get-task-allow": true, "aps-environment": "development"]
        let result = try reconcile(requested, granted: developmentGrants)
        #expect(result["aps-environment"] as? String == "development")
        #expect(Set(result.keys) == Set(requested.keys))
    }

    @Test func distributionOnlyEntitlementsAreDroppedWhenNotGranted() throws {
        let outcome = try EntitlementsReconciler.reconcile(
            entitlements([
                "beta-reports-active": true,
                "aps-environment": "production",
                "get-task-allow": false,
            ]),
            with: entitlements(developmentGrants),
            profileName: "dev profile"
        )
        let result = try outcome.entitlements.plistDictionary()
        #expect(outcome.removed == ["beta-reports-active"])
        #expect(result["beta-reports-active"] == nil)
        #expect(result["aps-environment"] as? String == "development")
    }

    @Test func distributionOnlyEntitlementsAreKeptWhenGranted() throws {
        var granted = developmentGrants
        granted["beta-reports-active"] = true
        let outcome = try EntitlementsReconciler.reconcile(
            entitlements(["beta-reports-active": true]), with: entitlements(granted), profileName: "p"
        )
        #expect(outcome.removed.isEmpty)
        #expect(try outcome.entitlements.plistDictionary()["beta-reports-active"] as? Bool == true)
    }
}
