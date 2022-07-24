//
//  SupersignGrandSlamTests.swift
//  SupersignTests
//
//  Created by Kabir Oberai on 10/04/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import XCTest
import SuperutilsTestSupport
@testable import Supersign

class TwoFactorAuthenticator: TwoFactorAuthDelegate {
    func fetchCode(completion: @escaping (String?) -> Void) {
        print("Code: ", terminator: "")
        completion(readLine() ?? "")
    }
}

class SupersignGrandSlamTests: XCTestCase {

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

    func testAuthentication() throws {
        let authWaiter = ResultWaiter<GrandSlamLoginData>(description: "Login timed out")
        GrandSlamAuthenticateOperation(
            client: client,
            username: Config.current.appleID.username,
            password: Config.current.appleID.password,
            twoFactorDelegate: authenticator
        ).authenticate(completion: authWaiter.completion)
        let loginData = try XCTTry(authWaiter.wait(timeout: 10000))
        XCTAssertFalse(loginData.adsid.isEmpty)
        XCTAssertFalse(loginData.cookie.isEmpty)
        XCTAssertFalse(loginData.identityToken.isEmpty)
        XCTAssertFalse(loginData.idmsToken.isEmpty)
        XCTAssertFalse(loginData.sk.isEmpty)

        let now = Date() // *before* the actual request is made

        let tokWaiter = ResultWaiter<[AppTokenKey: GrandSlamFetchAppTokensOperation.Token]>(
            description: "Token request timed out"
        )
        GrandSlamFetchAppTokensOperation(
            client: client,
            apps: [.xcode],
            loginData: loginData
        ).perform(completion: tokWaiter.completion)
        let tokens = try XCTTry(tokWaiter.wait(timeout: 10000))
        let token = try XCTUnwrap(tokens[.xcode], "Xcode token absent from response")
        XCTAssertGreaterThanOrEqual(token.expiry, now)
        XCTAssertFalse(token.value.isEmpty)
    }

}
