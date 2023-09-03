//
//  DeveloperServicesFetchCertificateOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

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

    public let context: SigningContext
    public let confirmRevocation: ([DeveloperServicesCertificate]) async -> Bool
    public init(
        context: SigningContext,
        confirmRevocation: @escaping ([DeveloperServicesCertificate]) async -> Bool
    ) {
        self.context = context
        self.confirmRevocation = confirmRevocation
    }

    private func createCertificate() async throws -> SigningInfo {
        let keypair = try Keypair()
        let csr = try keypair.generateCSR()
        let privateKey = try keypair.privateKey()

        let request = DeveloperServicesSubmitCSRRequest(
            platform: context.platform,
            teamID: context.teamID,
            csr: csr,
            machineName: "Supercharge: \(SigningContext.hostName)",
            machineID: context.client.deviceInfo.deviceID
        )
        let partialCert = try await context.client.send(request)

        let serialNumber = partialCert.serialNumber
        let listRequest = DeveloperServicesListCertificatesRequest(
            teamID: self.context.teamID, certificateKind: .init(platform: self.context.platform)
        )
        let certificates = try await context.client.send(listRequest)
        guard let fullCert = certificates.first(where: { $0.attributes.serialNumber == serialNumber })
            else { throw Error.csrFailed }
        return .init(privateKey: privateKey, certificate: fullCert.attributes.content)
    }

    private func revokeCreateSaveCertificate(certificates: [DeveloperServicesCertificate]) async throws -> SigningInfo {
        if !certificates.isEmpty {
            guard await confirmRevocation(certificates) 
                else { throw CancellationError() }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for certificate in certificates {
                group.addTask {
                    let request = DeveloperServicesRevokeCertificateRequest(
                        teamID: context.teamID, certificateID: certificate.id
                    )
                    _ = try await context.client.send(request)
                }
            }
            try await group.waitForAll()
        }
        let signingInfo = try await createCertificate()
        self.context.signingInfoManager[self.context.teamID] = signingInfo
        return signingInfo
    }

    public func perform() async throws -> SigningInfo {
        let request = DeveloperServicesListCertificatesRequest(
            teamID: context.teamID, certificateKind: .init(platform: context.platform)
        )
        let certificates = try await context.client.send(request)

        guard let certificate = certificates.first(where: {
            $0.attributes.machineID == self.context.client.deviceInfo.deviceID
        }) else {
            // we need to revoke existing certs, otherwise it doesn't always let us make a new one
            return try await self.revokeCreateSaveCertificate(certificates: certificates)
        }

        guard let signingInfo = self.context.signingInfoManager[self.context.teamID],
              certificate.attributes.serialNumber.rawValue == signingInfo.certificate.serialNumber(),
              certificate.attributes.expiry > Date() else {
            // we have a certificate for this machine but it's not usable
            return try await self.revokeCreateSaveCertificate(certificates: [certificate])
        }

        return signingInfo
    }

}
