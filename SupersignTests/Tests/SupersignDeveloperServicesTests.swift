//
//  SupersignDeveloperServicesTests.swift
//  SupersignTests
//
//  Created by Kabir Oberai on 30/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import XCTest
import Supersign

class SupersignDeveloperServicesTests: XCTestCase {

    var client: DeveloperServicesClient!

    override func setUp() {
        super.setUp()
        client = .test()
    }

    override func tearDown() {
        super.tearDown()
        client = nil
    }

    // integration test for provisioning
    func testProvisioningIntegration() throws {

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
