//
//  GrandSlamAuthenticateOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import Crypto
import _CryptoExtras

class GrandSlamAuthenticateOperation {

    enum Error: Swift.Error, LocalizedError {
        case internalError
        case failedSecondaryAuth

        var errorDescription: String? {
            switch self {
            case .internalError:
                return NSLocalizedString(
                    "apple_id_auth.error.internal",
                    value: "An internal authentication error occurred.",
                    comment: ""
                )
            case .failedSecondaryAuth:
                return NSLocalizedString(
                    "apple_id_auth.error.failed_secondary_auth",
                    value: "Could not complete 2-factor authentication.",
                    comment: ""
                )
            }
        }
    }

    private struct Response: Decodable {
        let statusCode: Int
        let url: String?

        private enum CodingKeys: String, CodingKey {
            case statusCode = "status-code"
            case url
        }
    }

    private let decoder = PropertyListDecoder()

    let client: GrandSlamClient
    let username: String
    let password: String
    unowned let twoFactorDelegate: TwoFactorAuthDelegate

    init(
        client: GrandSlamClient,
        username: String,
        password: String,
        twoFactorDelegate: TwoFactorAuthDelegate
    ) {
        self.client = client
        self.username = username
        self.password = password
        self.twoFactorDelegate = twoFactorDelegate
    }

    private func authenticateTwoFactor(
        mode: GrandSlamAuthMode?,
        loginData: GrandSlamLoginData
    ) async throws -> GrandSlamLoginData {
        let operation = GrandSlamTwoFactorAuthenticateOperation(
            client: client,
            mode: mode,
            loginData: loginData,
            delegate: twoFactorDelegate
        )
        try await operation.perform()
        return try await authenticate(isRetry: true)
    }

    private func authenticate(isRetry: Bool) async throws -> GrandSlamLoginData {
        var srpClient = SRPClient()

        srpClient.add(string: GrandSlamAuthInitRequest.protocols.joined(separator: ","))
        srpClient.add(string: "|")

        let publicKey = srpClient.publicKey()
        let initRequest = GrandSlamAuthInitRequest(username: username, publicKey: publicKey)
        let initResponse = try await client.send(initRequest)

        srpClient.add(string: "|")
        srpClient.add(string: initResponse.selectedProtocol.rawValue)

        let m1Data = try srpClient.processChallenge(
            withUsername: username,
            password: password,
            salt: initResponse.salt,
            iterations: initResponse.iterations,
            isLegacyProtocol: initResponse.selectedProtocol == .s2k_fo,
            serverPublicKey: initResponse.serverPublicKey
        )

        let completeRequest = GrandSlamAuthCompleteRequest(
            username: username, cookie: initResponse.cookie, m1Data: m1Data
        )
        let completeResponse = try await client.send(completeRequest)

        srpClient.add(string: "|")
        srpClient.add(data: completeResponse.encryptedResponse)
        srpClient.add(string: "|")
        completeResponse.sc.map { srpClient.add(data: $0) }
        srpClient.add(string: "|")

        guard srpClient.verify(hamk: completeResponse.hamk) && srpClient.verify(negProto: completeResponse.negProto)
            else { throw Error.internalError }

        let rawLoginResponse = try srpClient.decrypt(cbc: completeResponse.encryptedResponse)

        let response = try decoder.decode(Response.self, from: rawLoginResponse)

        let loginData = try decoder.decode(GrandSlamLoginData.self, from: rawLoginResponse)

        if response.statusCode == 409 {
            // 2FA
            guard !isRetry else { throw Error.failedSecondaryAuth }
            let authMode = response.url.flatMap { GrandSlamAuthMode(rawValue: $0) }
            return try await authenticateTwoFactor(
                mode: authMode,
                loginData: loginData
            )
        }

        return loginData
    }

    func authenticate() async throws -> GrandSlamLoginData {
        try await authenticate(isRetry: false)
    }

}
