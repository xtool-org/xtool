//
//  DeveloperServicesProvisioningOperation.swift
//  XKit
//
//  Created by Kabir Oberai on 12/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct ProvisioningInfo: Sendable {
    public let newBundleID: String
    public let entitlements: Entitlements
    public let mobileprovision: Mobileprovision
}

public struct DeveloperServicesProvisioningOperation: DeveloperServicesOperation {

    public struct Response {
        public let signingInfo: SigningInfo
        public let provisioningDict: [URL: ProvisioningInfo]
    }

    public let context: SigningContext
    public let app: URL
    public let confirmRevocation: @Sendable ([DeveloperServicesCertificate]) async -> Bool
    public let progress: @Sendable (Double) -> Void
    public init(
        context: SigningContext,
        app: URL,
        confirmRevocation: @escaping @Sendable ([DeveloperServicesCertificate]) async -> Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) {
        self.context = context
        self.app = app
        self.confirmRevocation = confirmRevocation
        self.progress = progress
    }

    public func perform() async throws -> Response {
        progress(0/3)
        _ = try await DeveloperServicesFetchDeviceOperation(context: context).perform()

        progress(1/3)
        let signingInfo = try await DeveloperServicesFetchCertificateOperation(
            context: self.context,
            confirmRevocation: confirmRevocation
        ).perform()

        progress(2/3)
        let provisioningDict = try await DeveloperServicesAddAppOperation(
            context: context,
            signingInfo: signingInfo,
            root: app
        ).perform()

        progress(3/3)
        return .init(signingInfo: signingInfo, provisioningDict: provisioningDict)
    }

}
