//
//  SupersignDeveloperServicesTests.swift
//  SupersignTests
//
//  Created by Kabir Oberai on 30/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import XCTest
import SuperutilsTestSupport
import Supersign

class SupersignDeveloperServicesTests: XCTestCase {

    var client: DeveloperServicesClient!

    override func setUp() {
        super.setUp()
        _ = addMockSigner
        client = .test()
    }

    override func tearDown() {
        super.tearDown()
        client = nil
    }

    // integration test for provisioning
    func testProvisioningIntegration() throws {
        let listTeams = DeveloperServicesListTeamsRequest()
        let teams = try XCTTry(client.sendTest(listTeams))
        let team = teams.first { $0.status == "active" && $0.memberships.contains { $0.platform == .iOS } }!

        let source = try XCTUnwrap(Bundle.module.url(forResource: "test", withExtension: "app"))

        let context = try XCTTry(SigningContext(
            udid: Config.current.udid,
            deviceName: SigningContext.hostName,
            teamID: team.id,
            client: client,
            signingInfoManager: MemoryBackedSigningInfoManager()
        ))

        let waiter = ResultWaiter<DeveloperServicesProvisioningOperation.Response>(description: "Failed to provision")
        DeveloperServicesProvisioningOperation(context: context, app: source) { _ in }
            .perform(completion: waiter.completion)
        let response = try XCTTry(waiter.wait(timeout: 10000))

        print(response)
    }

    func testListTeams() throws {
        let listTeams = DeveloperServicesListTeamsRequest()
        let teams = try XCTTry(client.sendTest(listTeams))
        XCTAssertFalse(teams.isEmpty, "No teams found")

        let team = try XCTUnwrap(
            teams.first { $0.id.rawValue == Config.current.preferredTeam },
            "Could not find preferred team"
        )

        XCTAssertEqual(team.status, "active", "Expected team status active. Got: \(team.status)")
        XCTAssert(team.memberships.contains { $0.platform == .iOS }, "Team does not have iOS membership")
    }

}
