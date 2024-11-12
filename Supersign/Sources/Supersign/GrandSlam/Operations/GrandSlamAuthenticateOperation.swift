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

    private var srpClient = SRPClient()
    private var isSecondAttempt = false

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

    private func restartAuth() async throws -> GrandSlamLoginData {
        srpClient = .init()
        isSecondAttempt = true
        return try await authenticate()
    }

    private func authenticateTwoFactor(
        mode: GrandSlamAuthMode?,
        loginData: GrandSlamLoginData
    ) async throws -> GrandSlamLoginData {
        guard !isSecondAttempt else { throw Error.failedSecondaryAuth }
        let operation = GrandSlamTwoFactorAuthenticateOperation(
            client: client,
            mode: mode,
            loginData: loginData,
            delegate: twoFactorDelegate
        )
        try await operation.perform()
        return try await self.restartAuth()
    }

    private func authenticateStage3(
        completeResponse: GrandSlamAuthCompleteRequest.Decoder.Value
    ) async throws -> GrandSlamLoginData {
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
            let authMode = response.url.flatMap { GrandSlamAuthMode(rawValue: $0) }
            return try await authenticateTwoFactor(
                mode: authMode,
                loginData: loginData
            )
        }

        return loginData
    }

    private func authenticateStage2(
        initResponse: GrandSlamAuthInitRequest.Decoder.Value
    ) async throws -> GrandSlamLoginData {
        srpClient.add(string: "|")
        srpClient.add(string: initResponse.selectedProtocol.rawValue)

        let hashedPassword = Data(SHA256.hash(data: Data(password.utf8)))
        let pbkdfInput = switch initResponse.selectedProtocol {
        case .s2k:
            hashedPassword
        case .s2k_fo:
            Data(hashedPassword.map { String(format: "%02hhx", $0) }.joined(separator: "").utf8)
        }
        let passkey = try KDF.Insecure.PBKDF2.deriveKey(
            from: pbkdfInput,
            salt: initResponse.salt,
            using: .sha256,
            outputByteCount: SHA256.byteCount,
            unsafeUncheckedRounds: initResponse.iterations
        )

        let mDataRaw = srpClient.processChallenge(
            withUsername: username,
            passkey: passkey.withUnsafeBytes { Data($0) },
            salt: initResponse.salt,
            serverPublicKey: initResponse.serverPublicKey
        )
        guard let m1Data = mDataRaw else { throw Error.internalError }

        let completeRequest = GrandSlamAuthCompleteRequest(
            username: username, cookie: initResponse.cookie, m1Data: m1Data
        )
        let response = try await client.send(completeRequest)
        return try await self.authenticateStage3(completeResponse: response)
    }

    func authenticate() async throws -> GrandSlamLoginData {
        srpClient.add(string: GrandSlamAuthInitRequest.protocols.joined(separator: ","))
        srpClient.add(string: "|")

        let publicKey = srpClient.publicKey()

        let initRequest = GrandSlamAuthInitRequest(username: username, publicKey: publicKey)
        let response = try await client.send(initRequest)
        return try await self.authenticateStage2(initResponse: response)
    }

}
