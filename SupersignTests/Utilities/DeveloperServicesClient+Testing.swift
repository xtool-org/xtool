//
//  DeveloperServicesTestClient.swift
//  SupersignTests
//
//  Created by Kabir Oberai on 06/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import XCTest
import Supersign

struct CredentialsManagerMock: DeveloperServicesCredentialsManager {
    // store login in memory
    public var token: DeveloperServicesCredentialsToken?
}

extension DeveloperServicesClient {

    static func test() -> DeveloperServicesClient {
        DeveloperServicesClient(
            loginToken: Config.current.appleID.token,
            deviceInfo: Config.current.deviceInfo,
            customAnisetteDataProvider: DirectAnisetteDataProvider()
        )
    }

    func sendTest<T: DeveloperServicesRequest>(
        _ request: T, file: StaticString = #file, line: UInt = #line
    ) throws -> T.Value {
        let waiter = ResultWaiter<T.Value>(description: "Could not finish request: \(request.action)")
        send(request, completion: waiter.completion)
        return try waiter.wait(timeout: 10, file: file, line: line)
    }

}
