//
//  GrandSlamTwoFactorAuthenticateOperation.swift
//  XKit
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public protocol TwoFactorAuthDelegate: AnyObject, Sendable {
    func fetchCode() async -> String?
}

struct GrandSlamTwoFactorAuthenticateOperation {

    enum Error: Swift.Error, LocalizedError {
        case incorrectVerificationCode
        case userCancelled
        case smsRejected(title: String, message: String)

        var errorDescription: String? {
            switch self {
            case .incorrectVerificationCode:
                return NSLocalizedString(
                    "apple_id_2fa.error.incorrect_code",
                    value: "Incorrect verification code.",
                    comment: ""
                )
            case .userCancelled:
                return NSLocalizedString(
                    "apple_id_2fa.error.user_cancelled",
                    value: "Verification was cancelled.",
                    comment: ""
                )
            case .smsRejected(let title, let message):
                return "\(title): \(message)"
            }
        }
    }

    let client: GrandSlamClient
    let mode: GrandSlamAuthMode?
    let loginData: GrandSlamLoginData
    unowned let delegate: TwoFactorAuthDelegate

    private func performSMSAuth() async throws {
        // Apple's SMS endpoint expects a phoneNumber.id that identifies which trusted phone number
        // to text. We don't yet parse the list from the o=complete response, so we try "1" first;
        // if Apple rejects it (e.g. "No Trusted Phone Numbers"), fall back to trusted-device 2FA.
        let phoneNumberID = "1"
        do {
            try await client.send(GrandSlamSMSAuthRequest(loginData: loginData, phoneNumberID: phoneNumberID))
        } catch let error as Error {
            guard case .smsRejected(let title, _) = error else { throw error }
            print("SMS 2FA unavailable (\(title)). Falling back to trusted-device verification.")
            try await performTrustedDeviceAuth()
            return
        }
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
