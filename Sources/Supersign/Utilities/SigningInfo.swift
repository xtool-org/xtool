//
//  SigningInfo.swift
//  Supersign
//
//  Created by Kabir Oberai on 12/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import ConcurrencyExtras

public struct SigningInfo: Codable, Sendable {
    public let privateKey: PrivateKey
    public let certificate: Certificate
}

public protocol SigningInfoManager: Sendable {
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

public final class MemoryBackedSigningInfoManager: SigningInfoManager {
    private let infos = LockIsolated<[String: SigningInfo]>([:])

    public init() {}

    public func info(forTeamID teamID: DeveloperServicesTeam.ID) throws -> SigningInfo? {
        infos[teamID.rawValue]
    }

    public func setInfo(_ info: SigningInfo?, forTeamID teamID: DeveloperServicesTeam.ID) throws {
        infos.withValue {
            $0[teamID.rawValue] = info
        }
    }
}

public struct KeyValueSigningInfoManager: SigningInfoManager {
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    public let storage: KeyValueStorage
    public init(storage: KeyValueStorage) {
        self.storage = storage
    }

    public func info(forTeamID teamID: DeveloperServicesTeam.ID) throws -> SigningInfo? {
        guard let data = try storage.data(forKey: teamID.rawValue)
            else { return nil }
        return try decoder.decode(SigningInfo.self, from: data)
    }

    public func setInfo(_ info: SigningInfo?, forTeamID teamID: DeveloperServicesTeam.ID) throws {
        let data = try encoder.encode(info)
        try storage.setData(data, forKey: teamID.rawValue)
    }
}
