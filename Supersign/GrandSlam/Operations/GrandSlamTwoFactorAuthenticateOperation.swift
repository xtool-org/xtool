//
//  GrandSlamTwoFactorAuthenticateOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public protocol TwoFactorAuthDelegate: class {
    func fetchCode(completion: @escaping (String) -> Void)
}

class GrandSlamTwoFactorAuthenticateOperation {

    enum Error: Swift.Error {
        case incorrectVerificationCode
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

    private func performSecondaryAuth(completion: @escaping (Result<(), Swift.Error>) -> Void) {
        let request = GrandSlamSecondaryAuthRequest(loginData: loginData)
        client.send(request) { result in
            guard result.get(withErrorHandler: completion) != nil else { return }
            self.delegate.fetchCode { self.validate(code: $0, completion: completion) }
        }
    }

    private func validate(code: String, completion: @escaping (Result<(), Swift.Error>) -> Void) {
        let request = GrandSlamValidateRequest(loginData: loginData, verificationCode: code)
        client.send(request) { result in
            switch result {
            case .success:
                completion(.success(()))
            case .failure(let error as GrandSlamOperationError) where error.code == -21669:
                completion(.failure(Error.incorrectVerificationCode))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func performTrustedDeviceAuth(completion: @escaping (Result<(), Swift.Error>) -> Void) {
        let request = GrandSlamTrustedDeviceRequest(loginData: loginData)
        client.send(request) { result in
            guard result.get(withErrorHandler: completion) != nil else { return }
            self.delegate.fetchCode { self.validate(code: $0, completion: completion) }
        }
    }

    func perform(completion: @escaping (Result<(), Swift.Error>) -> Void) {
        switch mode {
        case .secondaryAuth:
            self.performSecondaryAuth(completion: completion)
        case .trustedDeviceSecondaryAuth:
            self.performTrustedDeviceAuth(completion: completion)
        }
    }

}
