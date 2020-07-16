//
//  GrandSlamFetchAppTokensOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

struct AppTokenKey: Hashable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

extension AppTokenKey {
    static let xcode = AppTokenKey("com.apple.gs.xcode.auth")
}

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
    let apps: [AppTokenKey]
    let loginData: GrandSlamLoginData

    init(client: GrandSlamClient, apps: [AppTokenKey], loginData: GrandSlamLoginData) {
        self.client = client
        self.apps = apps
        self.loginData = loginData
    }

    private func handle(
        response: GrandSlamAppTokensRequest.Decoder.Value,
        completion: @escaping (Result<[AppTokenKey: Token], Swift.Error>) -> Void
    ) {
        guard let decrypted = AppTokens.decrypt(gcm: response.encryptedToken, withSK: loginData.sk)
            else { return completion(.failure(Error.invalidResponse)) }
        completion(Result {
            let pairs = try decoder
                .decode(Response.self, from: decrypted)
                .tokens
                .map { (AppTokenKey($0), $1) }
            return Dictionary(uniqueKeysWithValues: pairs)
        })
    }

    func perform(completion: @escaping (Result<[AppTokenKey: Token], Swift.Error>) -> Void) {
        let checksum = AppTokens.checksum(withSK: loginData.sk, adsid: loginData.adsid, apps: apps.map { $0.rawValue })
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
