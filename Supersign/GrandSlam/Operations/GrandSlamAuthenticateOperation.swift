//
//  GrandSlamAuthenticateOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

class GrandSlamAuthenticateOperation {

    enum Error: Swift.Error {
        case failedChallenge
        case invalidSession
        case invalidResponse
        case failedSecondaryAuth
    }

    private struct Response: Decodable {
        let statusCode: Int
        let url: String?

        private enum CodingKeys: String, CodingKey {
            case statusCode = "status-code"
            case url
        }
    }

    private var helper = SRPHelper()
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
        helper = .init()
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
        helper.addString(toNegProt: "|")
        helper.addData(toNegProt: completeResponse.encryptedResponse)
        helper.addString(toNegProt: "|")
        completeResponse.sc.map(helper.addData)
        helper.addString(toNegProt: "|")

        guard helper.verifySession(withM2: completeResponse.m2Data) && helper.verifyNegProto(completeResponse.negProto) else {
            return completion(.failure(Error.invalidSession))
        }

        guard let rawLoginResponse = helper.decryptCBC(completeResponse.encryptedResponse) else {
            return completion(.failure(Error.invalidResponse))
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
        helper.addString(toNegProt: "|")
        helper.addString(toNegProt: initResponse.selectedProtocol.rawValue)

        let mDataRaw = helper.processChallenge(
            withUsername: username,
            password: password,
            salt: initResponse.salt,
            iterations: initResponse.iterations,
            bData: initResponse.bData,
            isS2K: isS2K
        )
        guard let m1Data = mDataRaw else { return completion(.failure(Error.failedChallenge)) }

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
        helper.addString(toNegProt: GrandSlamAuthInitRequest.protocols.joined(separator: ","))
        helper.addString(toNegProt: "|")

        let aData = helper.startAuthenticationAndGetA()

        let initRequest = GrandSlamAuthInitRequest(username: username, aData: aData)
        client.send(initRequest) { result in
            guard let response = result.get(withErrorHandler: completion) else { return }
            self.authenticateStage2(initResponse: response, completion: completion)
        }
    }

}
