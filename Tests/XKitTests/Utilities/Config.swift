//
//  Config.swift
//  XKitTests
//
//  Created by Kabir Oberai on 05/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import XKit

struct Config: Decodable {
    struct AppleID: Decodable {
        let username: String
        let password: String
        /// for non-login tests, just provide a token already
        let token: DeveloperServicesLoginToken
    }

    let appleID: AppleID
    let deviceInfo: DeviceInfo
    let preferredTeam: String
    let udid: String

    static let current: Config = {
        let url = Bundle.module.url(forResource: "config", withExtension: "json")!
        // swiftlint:disable:next force_try
        let data = try! Data(contentsOf: url)
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Config.self, from: data)
    }()
}
