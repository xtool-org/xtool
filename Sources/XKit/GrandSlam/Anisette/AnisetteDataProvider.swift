//
//  AnisetteDataProvider.swift
//  XKit
//
//  Created by Kabir Oberai on 19/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import Dependencies

public protocol AnisetteDataProvider: Sendable {
    /// Stored alongside login data. If the provider reports a new version, we log out and reset provisioning.
    ///
    /// The default implementation returns `nil`.
    var providerVersion: String? { get }

    // This is a suggestion and not a requirement.
    func resetProvisioning()

    func provisioningData() -> ProvisioningData?

    func fetchAnisetteData() async throws -> AnisetteData
}

public struct ProvisioningData: Hashable, Codable, Sendable {
    public var localUserUID: UUID
    public var routingInfo: UInt64
    public var adiPb: Data
}

extension AnisetteDataProvider {
    public var providerVersion: String? { nil }
    public func provisioningData() -> ProvisioningData? { nil }
    public func resetProvisioning() {}
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
