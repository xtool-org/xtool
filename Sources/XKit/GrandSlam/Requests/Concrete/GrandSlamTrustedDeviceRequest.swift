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

/// The account's trusted phone numbers, to send the SMS to.
struct GrandSlamTrustedPhoneNumbersRequest: GrandSlamTwoFactorRequest {
    struct Decoder: GrandSlamDataDecoder {
        private struct Response: Decodable {
            struct PhoneNumber: Decodable {
                let id: Int
            }
            let trustedPhoneNumbers: [PhoneNumber]?
        }

        static func decode(data: Data) throws -> [Int] {
            try JSONDecoder().decode(Response.self, from: data).trustedPhoneNumbers?.map(\.id) ?? []
        }
    }

    static let endpoint: GrandSlamEndpoint = .url(URL(string: "https://gsa.apple.com/auth")!)

    let loginData: GrandSlamLoginData

    var extraHeaders: [String: String] {
        GrandSlamSMSAuthRequest.jsonHeaders
    }
}

struct GrandSlamSMSAuthRequest: GrandSlamTwoFactorRequest {
    struct Decoder: GrandSlamDataDecoder {
        static func decode(data: Data) throws {}
    }

    // the plist `POST /auth/verify/phone/put?mode=sms` gets a 403 ("Could not connect to iCloud");
    // Apple's own sign-in asks with JSON
    static let endpoint: GrandSlamEndpoint = .url(URL(string: "https://gsa.apple.com/auth/verify/phone")!)

    static let jsonHeaders = [
        "Content-Type": "application/json",
        "Accept": "application/json",
    ]

    let loginData: GrandSlamLoginData
    let phoneNumberID: Int

    var extraHeaders: [String: String] {
        Self.jsonHeaders
    }

    func method(anisetteData: AnisetteData) -> GrandSlamMethod {
        .json(.put, [
            "phoneNumber": ["id": phoneNumberID],
            "mode": "sms",
        ])
    }
}
