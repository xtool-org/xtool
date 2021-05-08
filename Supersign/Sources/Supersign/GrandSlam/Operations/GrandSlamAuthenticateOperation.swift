//
//  GrandSlamAuthenticateOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

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

    private func restartAuth(completion: @escaping (Result<GrandSlamLoginData, Swift.Error>) -> Void) {
        srpClient = .init()
        isSecondAttempt = true
        authenticate(completion: completion)
    }

    private func authenticateTwoFactor(
        mode: GrandSlamAuthMode,
        loginData: GrandSlamLoginData,
        completion: @escaping (Result<GrandSlamLoginData, Swift.Error>) -> Void
    ) {
        guard !isSecondAttempt else { return completion(.failure(Error.failedSecondaryAuth)) }
        let operation = GrandSlamTwoFactorAuthenticateOperation(
            client: client,
            mode: mode,
            loginData: loginData,
            delegate: twoFactorDelegate
        )
        operation.perform { result in
            guard result.get(withErrorHandler: completion) != nil else { return }
            self.restartAuth(completion: completion)
        }
    }

    private func authenticateStage3(
        completeResponse: GrandSlamAuthCompleteRequest.Decoder.Value,
        completion: @escaping (Result<GrandSlamLoginData, Swift.Error>) -> Void
    ) {
        srpClient.add(string: "|")
        srpClient.add(data: completeResponse.encryptedResponse)
        srpClient.add(string: "|")
        completeResponse.sc.map(srpClient.add(data:))
        srpClient.add(string: "|")

        guard srpClient.verify(hamk: completeResponse.hamk) && srpClient.verify(negProto: completeResponse.negProto)
            else { return completion(.failure(Error.internalError)) }

        guard let rawLoginResponse = srpClient.decrypt(cbc: completeResponse.encryptedResponse) else {
            return completion(.failure(Error.internalError))
        }

        let response: Response
        do {
            response = try decoder.decode(Response.self, from: rawLoginResponse)
        } catch {
            return completion(.failure(error))
        }

        let loginData: GrandSlamLoginData
        do {
            loginData = try decoder.decode(GrandSlamLoginData.self, from: rawLoginResponse)
        } catch {
            return completion(.failure(error))
        }

        if response.statusCode == 409,
            let secondaryURL = response.url,
            let authMode = GrandSlamAuthMode(rawValue: secondaryURL) {
            // 2FA
            return authenticateTwoFactor(
                mode: authMode,
                loginData: loginData,
                completion: completion
            )
        }

        completion(.success(loginData))
    }

    private func authenticateStage2(
        initResponse: GrandSlamAuthInitRequest.Decoder.Value,
        completion: @escaping (Result<GrandSlamLoginData, Swift.Error>) -> Void
    ) {
        let isS2K = initResponse.selectedProtocol == .s2k
        srpClient.add(string: "|")
        srpClient.add(string: initResponse.selectedProtocol.rawValue)

        let mDataRaw = srpClient.processChallenge(
            withUsername: username,
            password: password,
            salt: initResponse.salt,
            iterations: initResponse.iterations,
            serverPublicKey: initResponse.serverPublicKey,
            isS2K: isS2K
        )
        guard let m1Data = mDataRaw else { return completion(.failure(Error.internalError)) }

        let completeRequest = GrandSlamAuthCompleteRequest(
            username: username, cookie: initResponse.cookie, m1Data: m1Data
        )
        client.send(completeRequest) { result in
            guard let response = result.get(withErrorHandler: completion) else { return }
            self.authenticateStage3(completeResponse: response, completion: completion)
        }
    }

    func authenticate(
        completion: @escaping (Result<GrandSlamLoginData, Swift.Error>) -> Void
    ) {
        srpClient.add(string: GrandSlamAuthInitRequest.protocols.joined(separator: ","))
        srpClient.add(string: "|")

        let publicKey = srpClient.publicKey()

        let initRequest = GrandSlamAuthInitRequest(username: username, publicKey: publicKey)
        client.send(initRequest) { result in
            guard let response = result.get(withErrorHandler: completion) else { return }
            self.authenticateStage2(initResponse: response, completion: completion)
        }
    }

}
