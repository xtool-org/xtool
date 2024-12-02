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
                return "\(file)".withCString {
                    String.localizedStringWithFormat(
                        NSLocalizedString(
                            "signer.error.error_reading", value: "Error while reading %s", comment: ""
                        ), $0
                    )
                }
            case .errorWriting(let file):
                return "\(file)".withCString {
                    String.localizedStringWithFormat(
                        NSLocalizedString(
                            "signer.error.error_writing", value: "Error while writing %s", comment: ""
                        ), $0
                    )
                }
            }
        }
    }

    public let context: SigningContext
    public let confirmRevocation: @Sendable ([DeveloperServicesCertificate]) async -> Bool
    public init(
        context: SigningContext,
        confirmRevocation: @escaping @Sendable ([DeveloperServicesCertificate]) async -> Bool
    ) {
        self.context = context
        self.confirmRevocation = confirmRevocation
    }

    public func sign(
        app: URL,
        status: @escaping (String) -> Void,
        progress: @escaping @Sendable (Double?) -> Void,
        didProvision: @escaping () throws -> Void = {}
    ) async throws -> String {
        status(NSLocalizedString("signer.provisioning", value: "Provisioning", comment: ""))
        let response = try await DeveloperServicesProvisioningOperation(
            context: context,
            app: app,
            confirmRevocation: confirmRevocation,
            progress: progress
        ).perform()

        let provisioningDict = response.provisioningDict
        let signingInfo = response.signingInfo
        guard let mainInfo = provisioningDict[app] else {
            throw Error.errorReading("app bundle ID")
        }

        try didProvision()

        for (url, info) in provisioningDict {
            let infoPlist = url.appendingPathComponent("Info.plist")
            guard let data = try? Data(contentsOf: infoPlist),
                let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { throw Error.errorReading(infoPlist.lastPathComponent) }
            let nsDict = NSMutableDictionary(dictionary: dict)
            nsDict["CFBundleIdentifier"] = info.newBundleID
            guard nsDict.write(to: infoPlist, atomically: true) else {
                throw Error.errorWriting(infoPlist.lastPathComponent)
            }

            let profURL = url.appendingPathComponent("embedded.mobileprovision")
            if profURL.exists {
                try FileManager.default.removeItem(at: profURL)
            }
            try info.mobileprovision.data().write(to: profURL)
        }

        let entitlements = provisioningDict.mapValues(\.entitlements)

        status(NSLocalizedString("signer.signing", value: "Signing", comment: ""))
        try await context.signerImpl.sign(
            app: app,
            certificate: signingInfo.certificate,
            privateKey: signingInfo.privateKey,
            entitlementMapping: entitlements,
            progress: progress
        )

        return mainInfo.newBundleID
    }

}
