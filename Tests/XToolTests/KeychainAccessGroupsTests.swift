import Foundation
import Testing
@testable import XKit

private func keychainGroups(
    requesting requested: [String]?,
    teamID: String = "TEAM123456",
    bundleID: String = "XTL-1.com.example.app"
) throws -> [String]? {
    var entitlements = try Entitlements(
        entitlements: requested.map { [KeychainAccessGroupsEntitlement(rawValue: $0)] } ?? []
    )
    try entitlements.update(teamID: .init(rawValue: teamID), bundleID: bundleID)
    return try entitlements.entitlements()
        .compactMap { $0 as? KeychainAccessGroupsEntitlement }
        .first?
        .rawValue
}

@Test func keychainGroupsDefaultToTheAppsOwnGroup() throws {
    #expect(try keychainGroups(requesting: nil) == ["TEAM123456.XTL-1.com.example.app"])
    #expect(try keychainGroups(requesting: []) == ["TEAM123456.XTL-1.com.example.app"])
}

@Test func keychainGroupsKeepTheTeamsSharedGroups() throws {
    // the shared group is listed first here: the app's own group must still come out first.
    let groups = try keychainGroups(requesting: [
        "TEAM123456.com.example.shared",
        "TEAM123456.XTL-1.com.example.app",
        "TEAM123456.com.example.other",
    ])
    #expect(groups == [
        "TEAM123456.XTL-1.com.example.app",
        "TEAM123456.com.example.shared",
        "TEAM123456.com.example.other",
    ])
}

@Test func keychainGroupsDropWhatTheTeamCannotName() throws {
    let groups = try keychainGroups(requesting: [
        "OTHERTEAM1.com.example.shared",
        "TEAM123456.*",
        "$(AppIdentifierPrefix)com.example.shared",
        "TEAM123456.com.example.shared",
        "TEAM123456.com.example.shared",
    ])
    #expect(groups == [
        "TEAM123456.XTL-1.com.example.app",
        "TEAM123456.com.example.shared",
    ])
}
