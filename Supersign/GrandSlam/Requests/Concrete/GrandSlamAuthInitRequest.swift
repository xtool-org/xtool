//
//  GrandSlamAuthInitRequest.swift
//  Supersign
//
//  Created by Kabir Oberai on 19/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

struct GrandSlamAuthInitRequest: GrandSlamOperationRequest {

    typealias Decoder = GrandSlamOperationDecoder<Value>
    struct Value: Decodable {
        let selectedProtocol: GrandSlamAuthProtocol
        let cookie: String
        let salt: Data
        let iterations: Int
        let serverPublicKey: Data

        private enum CodingKeys: String, CodingKey {
            case selectedProtocol = "sp"
            case cookie = "c"
            case salt = "s"
            case iterations = "i"
            case serverPublicKey = "B"
        }
    }

    static let operation = "init"

    static let protocols: [String] =  GrandSlamAuthProtocol.allCases.map { $0.rawValue }

    let username: String
    let publicKey: Data

    var parameters: [String: Any] {
        [
            "ps": Self.protocols,
            "A2k": publicKey,
        ]
    }

}
