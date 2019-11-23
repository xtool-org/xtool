//
//  GrandSlamFetchAppTokensOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

class GrandSlamFetchAppTokensOperation {

    enum Error: Swift.Error {
        case invalidResponse
    }

    struct Token: Decodable {
        let value: String

        private let _expiry: Int
        var expiry: Date {
            Date(timeIntervalSince1970: .init(_expiry) / 1000)
        }

        private enum CodingKeys: String, CodingKey {
            case value = "token"
            case _expiry = "expiry"
        }
    }

    private struct Response: Decodable {
        let tokens: [String: Token]

        private enum CodingKeys: String, CodingKey {
            case tokens = "t"
        }
    }

    private let decoder = PropertyListDecoder()

    let client: GrandSlamClient
    let apps: [String]
    let loginData: GrandSlamLoginData

    init(client: GrandSlamClient, apps: [String], loginData: GrandSlamLoginData) {
        self.client = client
        self.apps = apps
        self.loginData = loginData
    }

    private func handle(
        response: GrandSlamAppTokensRequest.Decoder.Value,
        completion: @escaping (Result<[String: Token], Swift.Error>) -> Void
    ) {
        guard let decrypted = AppTokensHelper.decryptGCM(response.encryptedToken, sk: self.loginData.sk)
            else { return completion(.failure(Error.invalidResponse)) }
        completion(Result {
            try decoder.decode(Response.self, from: decrypted).tokens
        })
    }

    func perform(completion: @escaping (Result<[String: Token], Swift.Error>) -> Void) {
        let checksum = AppTokensHelper.createAppTokensChecksum(
            withSK: loginData.sk, adsid: loginData.adsid, apps: apps
        )
        let appTokensRequest = GrandSlamAppTokensRequest(
            username: loginData.adsid,
            apps: apps,
            cookie: loginData.cookie,
            idmsToken: loginData.idmsToken,
            checksum: checksum
        )
        client.send(appTokensRequest) { result in
            guard let response = result.get(withErrorHandler: completion) else { return }
            self.handle(response: response, completion: completion)
        }
    }

}
