//
//  GrandSlamTrustedDeviceRequest.swift
//  XKit
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

struct GrandSlamTrustedDeviceRequest: GrandSlamTwoFactorRequest {
    struct Decoder: GrandSlamDataDecoder {
        static func decode(data: Data) throws {}
    }

    static let endpoint: GrandSlamEndpoint = .lookup(\.trustedDeviceSecondaryAuth)

    let loginData: GrandSlamLoginData
}

struct GrandSlamSecondaryAuthRequest: GrandSlamTwoFactorRequest {
    struct Decoder: GrandSlamDataDecoder {
        static func decode(data: Data) throws {
//            print(String(data: data, encoding: .utf8) ?? "NO DATA")
        }
    }

    static let endpoint: GrandSlamEndpoint = .lookup(\.secondaryAuth)

    let loginData: GrandSlamLoginData
}

struct GrandSlamSMSAuthRequest: GrandSlamTwoFactorRequest {
    struct Decoder: GrandSlamDataDecoder {
        static func decode(data: Data) throws {}
    }

    static let endpoint: GrandSlamEndpoint = .url(URL(string: "https://gsa.apple.com/auth/verify/phone/put?mode=sms")!)

    let loginData: GrandSlamLoginData
    let phoneNumberID: String

    func content(anisetteData: AnisetteData) -> GrandSlamRequestContent {
        .post([
            "serverInfo": [
                "phoneNumber.id": phoneNumberID
            ],
        ])
    }
}
