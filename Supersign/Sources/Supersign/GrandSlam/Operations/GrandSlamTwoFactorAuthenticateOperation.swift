//
//  GrandSlamTwoFactorAuthenticateOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public protocol TwoFactorAuthDelegate: AnyObject {
    func fetchCode(completion: @escaping (String?) -> Void)
}

class GrandSlamTwoFactorAuthenticateOperation {

    enum Error: Swift.Error {
        case incorrectVerificationCode
        case userCancelled
    }

    let client: GrandSlamClient
    let mode: GrandSlamAuthMode
    let loginData: GrandSlamLoginData
    unowned let delegate: TwoFactorAuthDelegate
    init(
        client: GrandSlamClient,
        mode: GrandSlamAuthMode,
        loginData: GrandSlamLoginData,
        delegate: TwoFactorAuthDelegate
    ) {
        self.client = client
        self.mode = mode
        self.loginData = loginData
        self.delegate = delegate
    }

    private func performSecondaryAuth() async throws {
        try await client.send(GrandSlamSecondaryAuthRequest(loginData: loginData))
        let code = await withCheckedContinuation { continuation in
            self.delegate.fetchCode {
                continuation.resume(returning: $0)
            }
        }
        try await self.validate(code: code)
    }

    private func validate(code: String?) async throws {
        guard let code = code else { throw Error.userCancelled }
        let request = GrandSlamValidateRequest(loginData: loginData, verificationCode: code)
        do {
            try await client.send(request)
        } catch let error as GrandSlamOperationError where error.code == -21669 {
            throw Error.incorrectVerificationCode
        }
    }

    private func performTrustedDeviceAuth() async throws {
        let request = GrandSlamTrustedDeviceRequest(loginData: loginData)
        try await client.send(request)
        let code = await withCheckedContinuation { continuation in
            self.delegate.fetchCode {
                continuation.resume(returning: $0)
            }
        }
        try await self.validate(code: code)
    }

    func perform() async throws {
        switch mode {
        case .secondaryAuth:
            // TODO: We *should* be calling performSecondaryAuth – it does
            // seem like performTrustedDeviceAuth sometimes works here but
            // other times re-authenticating continues to 409
            try await self.performTrustedDeviceAuth()
        case .trustedDeviceSecondaryAuth:
            try await self.performTrustedDeviceAuth()
        }
    }

}
