//
//  GrandSlamTwoFactorAuthenticateOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public protocol TwoFactorAuthDelegate: AnyObject, Sendable {
    func fetchCode() async -> String?
}

struct GrandSlamTwoFactorAuthenticateOperation {

    enum Error: Swift.Error {
        case incorrectVerificationCode
        case userCancelled
    }

    let client: GrandSlamClient
    let mode: GrandSlamAuthMode?
    let loginData: GrandSlamLoginData
    unowned let delegate: TwoFactorAuthDelegate

    private func performSMSAuth() async throws {
        // TODO: parse phone number list from o=complete req?
        let phoneNumberID = "1"
        try await client.send(GrandSlamSMSAuthRequest(loginData: loginData, phoneNumberID: phoneNumberID))
        try await validateCode(phoneNumberID: phoneNumberID)
    }

    private func validateCode(phoneNumberID: String? = nil) async throws {
        guard let code = await self.delegate.fetchCode() else { throw Error.userCancelled }
        let request: any GrandSlamRequest = if let phoneNumberID {
            GrandSlamValidateSMSRequest(
                loginData: loginData,
                phoneNumberID: phoneNumberID,
                verificationCode: code
            )
        } else {
            GrandSlamValidateRequest(loginData: loginData, verificationCode: code)
        }
        do {
            _ = try await client.send(request)
        } catch let error as GrandSlamOperationError where error.code == -21669 {
            throw Error.incorrectVerificationCode
        }
    }

    private func performTrustedDeviceAuth() async throws {
        let request = GrandSlamTrustedDeviceRequest(loginData: loginData)
        try await client.send(request)
        try await validateCode()
    }

    func perform() async throws {
        switch mode {
        case .secondaryAuth:
            try await self.performSMSAuth()
        case .trustedDeviceSecondaryAuth:
            try await self.performTrustedDeviceAuth()
        case nil: // means 2FA was automatically requested
            try await validateCode()
        }
    }

}
