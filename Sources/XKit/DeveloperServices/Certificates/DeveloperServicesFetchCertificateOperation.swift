//
//  DeveloperServicesFetchCertificateOperation.swift
//  XKit
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import DeveloperAPI
import Dependencies

public typealias DeveloperServicesCertificate = Components.Schemas.Certificate

public struct DeveloperServicesFetchCertificateOperation: DeveloperServicesOperation {

    public enum Error: LocalizedError {
        case csrFailed
        case userCancelled

        public var errorDescription: String? {
            switch self {
            case .csrFailed:
                return NSLocalizedString(
                    "fetch_certificate_operation.error.csr_failed", value: "CSR request failed", comment: ""
                )
            case .userCancelled:
                return NSLocalizedString(
                    "fetch_certificate_operation.error.user_cancelled", value: "The operation was cancelled", comment: ""
                )
            }
        }
    }

    @Dependency(\.signingInfoManager) var signingInfoManager

    public let context: SigningContext
    public let confirmRevocation: @Sendable ([DeveloperServicesCertificate]) async -> Bool
    public init(
        context: SigningContext,
        confirmRevocation: @escaping @Sendable ([DeveloperServicesCertificate]) async -> Bool
    ) {
        self.context = context
        self.confirmRevocation = confirmRevocation
    }

    private func createCertificate() async throws -> SigningInfo {
        let keypair = try Keypair()
        let csr = try keypair.generateCSR()
        let privateKey = try keypair.privateKey()

        let response = try await context.developerAPIClient.certificatesCreateInstance(
            body: .json(.init(data: .init(
                _type: .certificates,
                attributes: .init(
                    csrContent: csr.pemString,
                    certificateType: .init(.development)
                )
            )))
        )

        guard let contentString = try response.created.body.json.data.attributes?.certificateContent,
              let contentData = Data(base64Encoded: contentString)
              else { throw Error.csrFailed }

        let certificate = try Certificate(data: contentData)

        return SigningInfo(privateKey: privateKey, certificate: certificate)
    }

    private func replaceCertificates(
        _ certificates: [DeveloperServicesCertificate],
        requireConfirmation: Bool
    ) async throws -> SigningInfo {
        if try await context.auth.team()?.isFree == true {
            if !certificates.isEmpty, requireConfirmation {
                guard await confirmRevocation(certificates)
                    else { throw CancellationError() }
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for certificate in certificates {
                    group.addTask {
                        _ = try await context.developerAPIClient
                            .certificatesDeleteInstance(path: .init(id: certificate.id))
                            .noContent
                    }
                }
                try await group.waitForAll()
            }
        }
        let signingInfo = try await createCertificate()
        signingInfoManager[self.context.auth.identityID] = signingInfo
        return signingInfo
    }

    public func perform() async throws -> SigningInfo {
        let certificates = try await context.developerAPIClient.certificatesGetCollection().ok.body.json.data

        guard let signingInfo = signingInfoManager[self.context.auth.identityID] else {
            return try await self.replaceCertificates(certificates, requireConfirmation: true)
        }

        let knownSerialNumber = signingInfo.certificate.serialNumber()
        guard let certificate = certificates.first(where: { $0.attributes?.serialNumber == knownSerialNumber }) else {
            // we need to revoke existing certs, otherwise it doesn't always let us make a new one
            return try await self.replaceCertificates(certificates, requireConfirmation: true)
        }

        if let date = certificate.attributes?.expirationDate, date > Date() {
            return signingInfo
        } else {
            // we have a certificate for this machine but it's not usable
            return try await self.replaceCertificates(
                [certificate],
                requireConfirmation: false
            )
        }
    }

}
