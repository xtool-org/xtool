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
    public init(context: SigningContext, app: URL) {
        self.context = context
        self.app = app
    }

    public func perform(completion: @escaping (Result<Response, Error>) -> Void) {
        DeveloperServicesFetchDeviceOperation(context: context).perform { result in
            guard result.get(withErrorHandler: completion) != nil else { return }
            DeveloperServicesFetchCertificateOperation(context: self.context).perform { result in
                guard let signingInfo = result.get(withErrorHandler: completion) else { return }
                DeveloperServicesAddAppOperation(context: self.context, root: self.app).perform { result in
                    guard let provisioningDict = result.get(withErrorHandler: completion) else { return }
                    completion(.success(.init(signingInfo: signingInfo, provisioningDict: provisioningDict)))
                }
            }
        }
    }

}
