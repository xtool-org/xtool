//
//  SigningInfo.swift
//  Supersign
//
//  Created by Kabir Oberai on 12/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct SigningInfo {
    public let privateKey: PrivateKey
    public let certificate: Certificate
}

public protocol SigningInfoManager {
    func info(forTeamID teamID: DeveloperServicesTeam.ID) throws -> SigningInfo?
    func setInfo(_ info: SigningInfo?, forTeamID teamID: DeveloperServicesTeam.ID) throws
}

extension SigningInfoManager {
    subscript(teamID: DeveloperServicesTeam.ID) -> SigningInfo? {
        get {
            try? info(forTeamID: teamID)
        }
        nonmutating set {
            try? setInfo(newValue, forTeamID: teamID)
        }
    }
}

public struct KeyValueSigningInfoManager: SigningInfoManager {
    private enum KeyType: String {
        case certificate
        case privateKey
    }

    private func key(_ teamID: DeveloperServicesTeam.ID, _ keyType: KeyType) -> String {
        "\(teamID).\(keyType.rawValue)"
    }

    public let storage: KeyValueStorage
    public init(storage: KeyValueStorage) {
        self.storage = storage
    }

    public func info(forTeamID teamID: DeveloperServicesTeam.ID) throws -> SigningInfo? {
        guard let privKeyData = try storage.data(forKey: key(teamID, .privateKey)),
            let certData = try storage.data(forKey: key(teamID, .certificate))
            else { return nil }
        let cert = try Certificate(data: certData)
        let privKey = PrivateKey(data: privKeyData)
        return SigningInfo(privateKey: privKey, certificate: cert)
    }

    public func setInfo(_ info: SigningInfo?, forTeamID teamID: DeveloperServicesTeam.ID) throws {
        try storage.setData(
            info?.certificate.data(),
            forKey: key(teamID, .certificate)
        )
        try storage.setData(
            info?.privateKey.data,
            forKey: key(teamID, .privateKey)
        )
    }
}
