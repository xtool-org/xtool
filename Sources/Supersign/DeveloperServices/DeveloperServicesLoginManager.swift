//
//  DeveloperServicesLoginManager.swift
//  Supersign
//
//  Created by Kabir Oberai on 10/04/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesLoginToken: Codable, Sendable {
    public let adsid: String
    public let token: String
    public let expiry: Date

    public init(adsid: String, token: String, expiry: Date) {
        self.adsid = adsid
        self.token = token
        self.expiry = expiry
    }
}

public struct DeveloperServicesLoginManager: Sendable {

    public enum Error: Swift.Error {
        case missingLoginToken
    }

    public let deviceInfo: DeviceInfo
    public let anisetteProvider: AnisetteDataProvider
    private let client: GrandSlamClient

    public init(
        deviceInfo: DeviceInfo,
        anisetteProvider: AnisetteDataProvider,
        httpFactory: HTTPClientFactory = defaultHTTPClientFactory
    ) throws {
        self.deviceInfo = deviceInfo
        self.anisetteProvider = anisetteProvider
        self.client = GrandSlamClient(
            deviceInfo: deviceInfo,
            anisetteProvider: anisetteProvider,
            httpFactory: httpFactory
        )
    }

    private func logIn(
        withLoginData loginData: GrandSlamLoginData
    ) async throws -> DeveloperServicesLoginToken {
        let tokens = try await GrandSlamFetchAppTokensOperation(
            client: client,
            apps: [.xcode],
            loginData: loginData
        ).perform()
        guard let token = tokens[.xcode]
            else { throw Error.missingLoginToken }
        return .init(adsid: loginData.adsid, token: token.value, expiry: token.expiry)
    }

    public func logIn(
        withUsername username: String,
        password: String,
        twoFactorDelegate: TwoFactorAuthDelegate
    ) async throws -> DeveloperServicesLoginToken {
        let loginData = try await GrandSlamAuthenticateOperation(
            client: client,
            username: username,
            password: password,
            twoFactorDelegate: twoFactorDelegate
        ).authenticate()
        _ = twoFactorDelegate
        return try await self.logIn(withLoginData: loginData)
    }

}
