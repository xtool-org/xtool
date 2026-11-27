//
//  GrandSlamValidateRequest.swift
//  XKit
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

struct GrandSlamValidateRequest: GrandSlamTwoFactorRequest {
    struct Decoder: GrandSlamDataDecoder {
        static func decode(data: Data) throws {}
    }

    static let endpoint: GrandSlamEndpoint = .lookup(\.validateCode)

    let loginData: GrandSlamLoginData
    let verificationCode: String

    var extraHeaders: [String: String] {
        ["security-code": verificationCode]
    }
}

struct GrandSlamValidateSMSRequest: GrandSlamTwoFactorRequest {
    struct Decoder: GrandSlamDataDecoder {
        static func decode(data: Data) throws {}
    }

    static let endpoint: GrandSlamEndpoint = .url(URL(
        string: "https://gsa.apple.com/auth/verify/phone/securitycode"
    )!)

    let loginData: GrandSlamLoginData
    let phoneNumberID: Int
    let verificationCode: String

    var extraHeaders: [String: String] {
        [
            "Content-Type": "application/json",
            "Accept": "application/json",
        ]
    }

    func content(anisetteData: AnisetteData) -> GrandSlamRequestContent {
        .post([
            "securityCode": ["code": verificationCode],
            "phoneNumber": ["id": phoneNumberID],
            "mode": "sms",
        ], type: .json)
    }
}
