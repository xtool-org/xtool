//
//  GrandSlamTwoFactorAuthenticateOperation.swift
//  XKit
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import XUtils
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
        let phoneNumberID: Int
        do {
            phoneNumberID = try await sendSMSCode()
        } catch let error as HTTPResponseError where error.status.code == 403 {
            d.out.print("""
            warning: Could not send verification code via SMS. Falling back to trusted device authentication...
            """)
            try await performTrustedDeviceAuth()
            return
        }
        try await validateCode(phoneNumberID: phoneNumberID)
    }

    /// Sends an SMS code and returns the ID of the phone number it was sent to.
    private func sendSMSCode() async throws -> Int {
        do {
            try await client.send(GrandSlamSMSAuthRequest(loginData: loginData, phoneNumberID: 1))
            return 1
        } catch let error as HTTPResponseError where error.status.code == 412 {
            // Apple rejects an unknown phone number ID with 412 and lists the account's trusted numbers.
            guard let phoneNumberID = Self.smsPhoneNumberID(in: error.body) else { throw error }
            try await client.send(GrandSlamSMSAuthRequest(loginData: loginData, phoneNumberID: phoneNumberID))
            return phoneNumberID
        }
    }

    static func smsPhoneNumberID(in body: String?) -> Int? {
        struct Response: Decodable {
            struct PhoneNumber: Decodable {
                let id: Int
                let pushMode: String?
            }
            let trustedPhoneNumbers: [PhoneNumber]
        }
        guard let data = body?.data(using: .utf8),
              let numbers = try? JSONDecoder().decode(Response.self, from: data).trustedPhoneNumbers
        else { return nil }
        return (numbers.first { $0.pushMode == "sms" } ?? numbers.first)?.id
    }

    private func validateCode(phoneNumberID: Int? = nil) async throws {
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
            d.out.print("""
            warning: Could not send verification code. Generate one manually.
                     See https://github.com/xtool-org/xtool/discussions/368
            """)
        }
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
