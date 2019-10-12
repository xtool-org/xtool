//
//  Signer.swift
//  Supersign
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct Signer {

    public enum Error: LocalizedError {
        case noSigners
        case errorReading(String)
        case errorWriting(String)

        public var errorDescription: String? {
            switch self {
            case .noSigners:
                return NSLocalizedString("signer.error.no_signers", value: "No signers found", comment: "")
            case .errorReading(let file):
                return String.localizedStringWithFormat(
                    NSLocalizedString(
                        "signer.error.error_reading", value: "Error while reading %@", comment: ""
                    ), "\(file)"
                )
            case .errorWriting(let file):
                return String.localizedStringWithFormat(
                    NSLocalizedString(
                        "signer.error.error_writing", value: "Error while writing %@", comment: ""
                    ), "\(file)"
                )
            }
        }
    }

    public let context: SigningContext
    public let provisioner: Provisioner

    public init(context: SigningContext) {
        self.context = context
        self.provisioner = Provisioner(context: context)
    }

    private func sign(
        app: URL,
        signingInfo: SigningInfo,
        provisioningDict: [URL: ProvisioningInfo],
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, Swift.Error>) -> Void
    ) {
        for (url, info) in provisioningDict {
            let infoPlist = url.appendingPathComponent("Info.plist")
            guard let dict = NSMutableDictionary(contentsOf: infoPlist) else {
                return completion(.failure(Error.errorReading("Info.plist")))
            }
            dict[kCFBundleIdentifierKey as String] = info.newBundleID
            guard dict.write(to: infoPlist, atomically: true) else {
                return completion(.failure(Error.errorWriting("Info.plist")))
            }

            do {
                let profURL = url.appendingPathComponent("embedded.mobileprovision")
                if profURL.exists {
                    try FileManager.default.removeItem(at: profURL)
                }
                try info.mobileprovision.data().write(to: profURL)
            } catch {
                return completion(.failure(error))
            }
        }

        let entitlements = provisioningDict.mapValues { $0.entitlements }

        context.signerImpl.sign(
            app: app,
            certificate: signingInfo.certificate,
            privateKey: signingInfo.privateKey,
            entitlementMapping: entitlements,
            progress: progress,
            completion: completion
        )
    }

    public func sign(
        app: URL,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, Swift.Error>) -> Void
    ) {
        provisioner.provision(app: app) { r in
            guard let (signingInfo, provisioningDict) = r.get(withErrorHandler: completion) else { return }
            self.sign(
                app: app,
                signingInfo: signingInfo,
                provisioningDict: provisioningDict,
                progress: progress,
                completion: completion
            )
        }
    }

}
