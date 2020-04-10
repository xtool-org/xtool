//
//  GrandSlamAppTokensRequest.swift
//  Supersign
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

struct GrandSlamAppTokensRequest: GrandSlamOperationRequest {

    typealias Decoder = GrandSlamOperationDecoder<Value>
    struct Value: Decodable {
        let encryptedToken: Data

        private enum CodingKeys: String, CodingKey {
            case encryptedToken = "et"
        }
    }

    static let operation = "apptokens"

    let username: String
    let apps: [AppTokenKey]
    let cookie: Data
    let idmsToken: String
    let checksum: Data

    var parameters: [String: Any] {
        [
            "app": apps.map { $0.rawValue },
            "c": cookie,
            "t": idmsToken,
            "checksum": checksum
        ]
    }

}
