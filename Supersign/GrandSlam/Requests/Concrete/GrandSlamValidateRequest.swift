//
//  GrandSlamValidateRequest.swift
//  Supersign
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

struct GrandSlamValidateRequest: GrandSlamTwoFactorRequest {
    struct Decoder: GrandSlamDataDecoder {
        static func decode(data: Data) throws {}
    }

    static let endpoint: GrandSlamEndpoint = \.validateCode

    let loginData: GrandSlamLoginData
    let verificationCode: String

    var extraHeaders: [String: String] {
        ["security-code": verificationCode]
    }
}
