//
//  GrandSlamFetchAppTokensOperation.swift
//  XKit
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

struct GrandSlamFetchAppTokensOperation {

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

    private static let decoder = PropertyListDecoder()

    let client: GrandSlamClient
    let apps: [AppTokenKey]
    let loginData: GrandSlamLoginData

    private func handle(
        response: GrandSlamAppTokensRequest.Decoder.Value
    ) async throws -> [AppTokenKey: Token] {
        let decrypted = try AppTokens.decrypt(gcm: response.encryptedToken, withSK: loginData.sk)
        let pairs = try Self.decoder
            .decode(Response.self, from: decrypted)
            .tokens
            .map { (AppTokenKey($0), $1) }
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    func perform() async throws -> [AppTokenKey: Token] {
        let checksum = AppTokens.checksum(withSK: loginData.sk, adsid: loginData.adsid, apps: apps.map { $0.rawValue })
        print("Got checksum")
        let appTokensRequest = GrandSlamAppTokensRequest(
            username: loginData.adsid,
            apps: apps,
            cookie: loginData.cookie,
            idmsToken: loginData.idmsToken,
            checksum: checksum
        )
        print("Sending tokens req")
        let response = try await client.send(appTokensRequest)
        print("Handling tokens resp")
        return try await self.handle(response: response)
    }

}
