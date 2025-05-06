//
//  AnisetteDataProvider.swift
//  Supersign
//
//  Created by Kabir Oberai on 19/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import Dependencies

public protocol AnisetteDataProvider: Sendable {
    // This is a suggestion and not a requirement.
    func resetProvisioning() async
    func provisioningData() -> ProvisioningData?

    func fetchAnisetteData() async throws -> AnisetteData
}

public struct ProvisioningData: Hashable, Codable, Sendable {
    public var localUserUID: UUID
    public var routingInfo: UInt64
    public var adiPb: Data
}

extension AnisetteDataProvider {
    public func provisioningData() -> ProvisioningData? { nil }
    public func resetProvisioning() async {}
}

extension DependencyValues {
    public var anisetteDataProvider: AnisetteDataProvider {
        get { self[AnisetteDataProviderDependencyKey.self] }
        set { self[AnisetteDataProviderDependencyKey.self] = newValue }
    }
}

private struct AnisetteDataProviderDependencyKey: DependencyKey {
    static let testValue: AnisetteDataProvider = UnimplementedAnisetteDataProvider()
    static let liveValue: AnisetteDataProvider = ADIDataProvider()
}

private struct UnimplementedAnisetteDataProvider: AnisetteDataProvider {
    func fetchAnisetteData() async throws -> AnisetteData {
        let closure: () async throws -> AnisetteData = unimplemented()
        return try await closure()
    }
}
