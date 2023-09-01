//
//  DeveloperServicesProvisioningOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 12/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct ProvisioningInfo {
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
    public let confirmRevocation: ([DeveloperServicesCertificate]) async -> Bool
    public let progress: (Double) -> Void
    public init(
        context: SigningContext,
        app: URL,
        confirmRevocation: @escaping ([DeveloperServicesCertificate]) async -> Bool,
        progress: @escaping (Double) -> Void
    ) {
        self.context = context
        self.app = app
        self.confirmRevocation = confirmRevocation
        self.progress = progress
    }

    public func perform(completion: @escaping (Result<Response, Error>) -> Void) {
        progress(0/3)
        DeveloperServicesFetchDeviceOperation(context: context).perform { result in
            guard result.get(withErrorHandler: completion) != nil else { return }
            self.progress(1/3)
            DeveloperServicesFetchCertificateOperation(
                context: self.context,
                confirmRevocation: confirmRevocation
            ).perform { result in
                guard let signingInfo = result.get(withErrorHandler: completion) else { return }
                self.progress(2/3)
                DeveloperServicesAddAppOperation(context: self.context, root: self.app).perform { result in
                    guard let provisioningDict = result.get(withErrorHandler: completion) else { return }
                    self.progress(3/3)
                    completion(.success(.init(signingInfo: signingInfo, provisioningDict: provisioningDict)))
                }
            }
        }
    }

}
