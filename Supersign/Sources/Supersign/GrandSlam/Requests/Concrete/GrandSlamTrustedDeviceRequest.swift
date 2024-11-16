//
//  GrandSlamTrustedDeviceRequest.swift
//  Supersign
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
