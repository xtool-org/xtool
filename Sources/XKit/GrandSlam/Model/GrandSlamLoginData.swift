//
//  GrandSlamLoginData.swift
//  XKit
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

struct GrandSlamLoginData: Decodable {
    let adsid: String
    let idmsToken: String
    let sk: Data
    let cookie: Data

    var identityToken: String {
        "\(adsid):\(idmsToken)".data(using: .utf8)!.base64EncodedString()
    }

    private enum CodingKeys: String, CodingKey {
        case adsid
        case idmsToken = "GsIdmsToken"
        case sk
        case cookie = "c"
    }
}
