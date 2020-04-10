//
//  DeveloperServicesLoginManager.swift
//  Supersign
//
//  Created by Kabir Oberai on 10/04/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesLoginToken: Codable {
    public let adsid: String
    public let token: String
    public let expiry: Date

    public init(adsid: String, token: String, expiry: Date) {
        self.adsid = adsid
        self.token = token
        self.expiry = expiry
    }
}

public struct DeveloperServicesLoginManager {

    public enum Error: Swift.Error {
        case missingLoginToken
    }

    public let deviceInfo: DeviceInfo
    public let anisetteProvider: AnisetteDataProvider
    private let client: GrandSlamClient

    public init(
        deviceInfo: DeviceInfo,
        customAnisetteProvider: AnisetteDataProvider? = nil
    ) {
        self.deviceInfo = deviceInfo
        self.anisetteProvider = customAnisetteProvider ?? ComputedAnisetteDataProvider(deviceInfo: deviceInfo)
        self.client = GrandSlamClient(deviceInfo: deviceInfo, customAnisetteDataProvider: anisetteProvider)
    }

    private func logIn(
        withLoginData loginData: GrandSlamLoginData,
        completion: @escaping (Result<DeveloperServicesLoginToken, Swift.Error>) -> Void
    ) {
        GrandSlamFetchAppTokensOperation(
            client: client,
            apps: [.xcode],
            loginData: loginData
        ).perform { result in
            guard let tokens = result.get(withErrorHandler: completion) else { return }
            guard let token = tokens[.xcode]
                else { return completion(.failure(Error.missingLoginToken)) }
            completion(.success(.init(adsid: loginData.adsid, token: token.value, expiry: token.expiry)))
        }
    }

    public func logIn(
        withUsername username: String,
        password: String,
        twoFactorDelegate: TwoFactorAuthDelegate,
        completion: @escaping (Result<DeveloperServicesLoginToken, Swift.Error>) -> Void
    ) {
        GrandSlamAuthenticateOperation(
            client: client,
            username: username,
            password: password,
            twoFactorDelegate: twoFactorDelegate
        ).authenticate { result in
            guard let loginData = result.get(withErrorHandler: completion) else { return }
            self.logIn(withLoginData: loginData, completion: completion)
        }
    }

}
