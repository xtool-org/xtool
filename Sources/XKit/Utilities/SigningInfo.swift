//
//  SigningInfo.swift
//  XKit
//
//  Created by Kabir Oberai on 12/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import ConcurrencyExtras
import Dependencies

public struct SigningInfo: Codable, Sendable {
    public let privateKey: PrivateKey
    public let certificate: Certificate
}

public protocol SigningInfoManager: Sendable {
    func info(forIdentityID identityID: String) throws -> SigningInfo?
    func setInfo(_ info: SigningInfo?, forIdentityID identityID: String) throws
}

public enum SigningInfoManagerDependencyKey: DependencyKey {
    public static let testValue: SigningInfoManager = UnimplementedSigningInfoManager()
    public static let liveValue: SigningInfoManager = KeyValueSigningInfoManager()
}

extension DependencyValues {
    public var signingInfoManager: SigningInfoManager {
        get { self[SigningInfoManagerDependencyKey.self] }
        set { self[SigningInfoManagerDependencyKey.self] = newValue }
    }
}

extension SigningInfoManager {
    subscript(identityID: String) -> SigningInfo? {
        get {
            try? info(forIdentityID: identityID)
        }
        nonmutating set {
            try? setInfo(newValue, forIdentityID: identityID)
        }
    }
}

private struct UnimplementedSigningInfoManager: SigningInfoManager {
    func info(forIdentityID identityID: String) throws -> SigningInfo? {
        unimplemented(placeholder: nil)
    }
    
    func setInfo(_ info: SigningInfo?, forIdentityID identityID: String) throws {
        unimplemented()
    }
}

public final class MemoryBackedSigningInfoManager: SigningInfoManager {
    private let infos = LockIsolated<[String: SigningInfo]>([:])

    public init() {}

    public func info(forIdentityID identityID: String) throws -> SigningInfo? {
        infos[identityID]
    }

    public func setInfo(_ info: SigningInfo?, forIdentityID identityID: String) throws {
        infos.withValue {
            $0[identityID] = info
        }
    }
}

public struct KeyValueSigningInfoManager: SigningInfoManager {
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    @Dependency(\.keyValueStorage) var storage

    public func info(forIdentityID identityID: String) throws -> SigningInfo? {
        guard let data = try storage.data(forKey: identityID)
            else { return nil }
        return try decoder.decode(SigningInfo.self, from: data)
    }

    public func setInfo(_ info: SigningInfo?, forIdentityID identityID: String) throws {
        let data = try encoder.encode(info)
        try storage.setData(data, forKey: identityID)
    }
}
