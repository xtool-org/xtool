import Testing
@testable import XKit

struct SharedKeychainGroupsTests {
    private let team = DeveloperServicesTeam.ID(rawValue: "NEWTEAM123")

    @Test func keepsSharedGroupsWrittenWithXcodePlaceholders() throws {
        var entitlements = try Entitlements(entitlements: [
            KeychainAccessGroupsEntitlement(rawValue: [
                "$(AppIdentifierPrefix)com.example.shared",
                "$(TeamIdentifierPrefix)com.example.other",
            ]),
        ])
        try entitlements.update(teamID: team, bundleID: "com.example.app.Widget")
        let groups = try #require(
            try entitlements.entitlements().lazy.compactMap { $0 as? KeychainAccessGroupsEntitlement }.first
        )
        #expect(groups.rawValue == [
            "NEWTEAM123.com.example.app.Widget",
            "NEWTEAM123.com.example.shared",
            "NEWTEAM123.com.example.other",
        ])
    }

    @Test func rescopesGroupsFromAnotherTeam() throws {
        let shared = Entitlements.sharedKeychainGroups(
            ["OLDTEAM456.com.example.shared"], teamID: team, bundleID: "com.example.app"
        )
        #expect(shared == ["NEWTEAM123.com.example.shared"])
    }

    @Test func prefixesGroupsWhosePlaceholderTheBuildExpandedToNothing() {
        // SwiftBuild expands $(AppIdentifierPrefix) to "" since the team is only known at signing time.
        let shared = Entitlements.sharedKeychainGroups(
            ["com.example.shared"], teamID: team, bundleID: "com.example.app.Widget"
        )
        #expect(shared == ["NEWTEAM123.com.example.shared"])
    }

    @Test func dropsTheAppsOwnFormerGroupAndWildcards() {
        let shared = Entitlements.sharedKeychainGroups(
            [
                "OLDTEAM456.com.example.app",  // the app's own group, now NEWTEAM123.<new bundle ID>
                "com.example.app",
                "OLDTEAM456.*",
                "$(AppIdentifierPrefix)",
            ],
            teamID: team,
            bundleID: "XTL-ABCD.com.example.app"
        )
        #expect(shared.isEmpty)
    }

    @Test func withNoRequestedGroupsOnlyTheAppsOwnGroupRemains() throws {
        var entitlements = try Entitlements(entitlements: [])
        try entitlements.update(teamID: team, bundleID: "com.example.app")
        let groups = try #require(
            try entitlements.entitlements().lazy.compactMap { $0 as? KeychainAccessGroupsEntitlement }.first
        )
        #expect(groups.rawValue == ["NEWTEAM123.com.example.app"])
    }
}
