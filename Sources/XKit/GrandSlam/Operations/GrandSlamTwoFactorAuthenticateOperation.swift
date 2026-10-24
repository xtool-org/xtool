//
//  GrandSlamTwoFactorAuthenticateOperation.swift
//  XKit
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public enum TwoFactorAuthMethod: CaseIterable, Sendable {
    case automatic
    case trustedDevice
    case manualCode
    case sms
}

public protocol TwoFactorAuthDelegate: AnyObject, Sendable {
    func selectMethod() async -> TwoFactorAuthMethod
    func fetchCode() async -> String?
}

public extension TwoFactorAuthDelegate {
    func selectMethod() async -> TwoFactorAuthMethod { .automatic }
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
        do {
            try await client.send(GrandSlamSMSAuthRequest(loginData: loginData, phoneNumberID: phoneNumberID))
        } catch let error as HTTPResponseError where error.status.code == 403 {
            print("""
            warning: Could not send verification code via SMS. Falling back to trusted device authentication...
            """)
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
        do {
            try await client.send(request)
        } catch let error as HTTPResponseError where error.status.code == 403 {
            print("""
            warning: Could not send verification code. Generate one manually.
                     See https://github.com/xtool-org/xtool/discussions/368
            """)
        }
        try await validateCode()
    }

    func perform() async throws {
        switch await delegate.selectMethod() {
        case .automatic:
            switch mode {
            case .secondaryAuth:
                try await performSMSAuth()
            case .trustedDeviceSecondaryAuth:
                try await performTrustedDeviceAuth()
            case nil: // means 2FA was automatically requested
                try await validateCode()
            }
        case .trustedDevice:
            print("Using trusted-device verification. Enter a code from your Apple device.")
            try await performTrustedDeviceAuth()
        case .manualCode:
            print("Using a manually generated Apple verification code.")
            try await validateCode()
        case .sms:
            try await performSMSAuth()
        }
    }

}
