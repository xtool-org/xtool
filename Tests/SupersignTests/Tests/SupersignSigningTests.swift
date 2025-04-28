//
//  SupersignSigningTests.swift
//  SupersignTests
//
//  Created by Kabir Oberai on 06/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

// TODO: Test using mock signer

#if false

import XCTest
import SuperutilsTestSupport
import Supersign

class SupersignSigningTests: XCTestCase {

    var client: DeveloperServicesClient!
    var signerImpl: SignerImpl!
    var app: URL!

    // swiftlint:disable force_try
    override func setUp() {
        super.setUp()
        _ = addMockSigner
        client = .test()
        signerImpl = try! SignerImpl.first()

        let source = try! XCTUnwrap(Bundle.module.url(forResource: "test", withExtension: "app"))
        let tmp = FileManager.default.temporaryDirectory
        app = tmp.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: app.path) {
            try! FileManager.default.removeItem(at: app)
        }
        try! FileManager.default.copyItem(at: source, to: app)
    }

    override func tearDown() {
        super.tearDown()
        client = nil
        signerImpl = nil
        try! FileManager.default.removeItem(at: app)
        app = nil
    }
    // swiftlint:enable force_try

    // integration test for signing
    @MainActor func testSigningIntegration() throws {
        let listTeams = DeveloperServicesListTeamsRequest()
        let teams = try XCTTry(client.sendTest(listTeams))
        let team = teams.first { $0.status == "active" && $0.memberships.contains { $0.platform == .iOS } }!

        let context = try XCTTry(SigningContext(
            udid: Config.current.udid,
            deviceName: SigningContext.hostName,
            teamID: team.id,
            client: client,
            signingInfoManager: MemoryBackedSigningInfoManager(),
            signerImpl: signerImpl
        ))
        let signer = Signer(context: context)

        let signingWaiter = ResultWaiter<()>(description: "Failed to sign app")
        signer.sign(app: app, status: { _ in }, progress: { _ in }, completion: signingWaiter.completion)
        try XCTTry(signingWaiter.wait(timeout: 10000))

        // TODO: Ensure entitlements are correct in new app, also codesign -vvvv
    }

    func testAnalyze() throws {
        let infoURL = app.appendingPathComponent("Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: infoURL))
        let execName = try XCTUnwrap(info[kCFBundleExecutableKey as String] as? String)
        let exec = app.appendingPathComponent(execName)

        let ents = try XCTUnwrap(signerImpl.analyze(executable: exec))
        let entsPlist = try XCTTry(PropertyListDecoder().decode(Entitlements.self, from: ents))

        XCTAssertFalse(try XCTTry(entsPlist.entitlements().isEmpty))
    }

    func testSign() throws {
        let signingWaiter = ResultWaiter<()>(description: "Failed to sign app")
        // TODO: Get cert, key, ents from fixtures
    }

}

#endif
