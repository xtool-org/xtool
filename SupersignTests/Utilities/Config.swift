//
//  Config.swift
//  SupersignTests
//
//  Created by Kabir Oberai on 05/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

struct Config: Decodable {
    struct AppleID: Decodable {
        let username: String
        let password: String
        /// for non-login tests, just provide a token already so that the 2fa prompt isn't invoked
        let token: String
    }
    let appleID: AppleID

    let preferredTeam: String

    static let current: Config = {
        class ConfigDummy {}
        let url = Bundle(for: ConfigDummy.self).url(forResource: "config", withExtension: "json")!
        // swiftlint:disable:next force_try
        let data = try! Data(contentsOf: url)
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Config.self, from: data)
    }()
}
