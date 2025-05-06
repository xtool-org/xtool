//
//  XKitGrandSlamTests.swift
//  XKitTests
//
//  Created by Kabir Oberai on 10/04/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

// swiftlint:disable force_try

import XCTest
import SuperutilsTestSupport
@testable import XKit

final class TwoFactorAuthenticator: TwoFactorAuthDelegate {
    func fetchCode() async -> String? {
        print("Code: ", terminator: "")
        return readLine() ?? ""
    }
}

class XKitGrandSlamTests: XCTestCase {

    var authenticator: TwoFactorAuthenticator!
    var storage: KeyValueStorage!
    var client: GrandSlamClient!

    override func setUp() {
        super.setUp()
        _ = addMockSigner
        storage = MemoryKeyValueStorage()
        client = try! .test(storage: storage)
        authenticator = TwoFactorAuthenticator()
    }

    override func tearDown() {
        super.tearDown()
        client = nil
        authenticator = nil
    }

    func testAuthentication() async throws {
        let loginData = try await GrandSlamAuthenticateOperation(
            client: client,
            username: Config.current.appleID.username,
            password: Config.current.appleID.password,
            twoFactorDelegate: authenticator
        ).authenticate()
        XCTAssertFalse(loginData.adsid.isEmpty)
        XCTAssertFalse(loginData.cookie.isEmpty)
        XCTAssertFalse(loginData.identityToken.isEmpty)
        XCTAssertFalse(loginData.idmsToken.isEmpty)
        XCTAssertFalse(loginData.sk.isEmpty)

        let now = Date() // *before* the actual request is made

        let tokens = try await GrandSlamFetchAppTokensOperation(
            client: client,
            apps: [.xcode],
            loginData: loginData
        ).perform()
        let token = try XCTUnwrap(tokens[.xcode], "Xcode token absent from response")
        XCTAssertGreaterThanOrEqual(token.expiry, now)
        XCTAssertFalse(token.value.isEmpty)
    }

}
