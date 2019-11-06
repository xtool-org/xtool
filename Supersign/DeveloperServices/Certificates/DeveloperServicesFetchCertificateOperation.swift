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

        public var errorDescription: String? {
            switch self {
            case .csrFailed:
                return NSLocalizedString(
                    "certificate_request_helper.error.csr_failed", value: "CSR request failed", comment: ""
                )
            }
        }
    }

    public let context: SigningContext
    public init(context: SigningContext) {
        self.context = context
    }

    private func createCertificate(
        completion: @escaping (Result<SigningInfo, Swift.Error>) -> Void
    ) {
        let csr: CSR
        let privateKey: PrivateKey
        do {
            let keypair = try Keypair()
            csr = try keypair.generateCSR()
            privateKey = try keypair.privateKey()
        } catch {
            return completion(.failure(error))
        }

        let request = DeveloperServicesSubmitCSRRequest(
            platform: context.platform,
            teamID: context.team.id,
            csr: csr,
            machineName: context.deviceName,
            machineID: context.udid
        )
        context.client.send(request) { result in
            guard let partialCert = result.get(withErrorHandler: completion) else { return }
            let serialNumber = partialCert.serialNumber

            let request = DeveloperServicesListCertificatesRequest(
                platform: self.context.platform,
                teamID: self.context.team.id
            )
            self.context.client.send(request) { result in
                guard let certificates = result.get(withErrorHandler: completion) else { return }
                guard let fullCert = certificates.first(where: { $0.serialNumber == serialNumber })
                    else { return completion(.failure(Error.csrFailed)) }
                completion(.success(.init(privateKey: privateKey, certificate: fullCert.content)))
            }
        }
    }

    private func createAndSaveCertificate(
        completion: @escaping (Result<SigningInfo, Swift.Error>) -> Void
    ) {
        createCertificate { result in
            guard let value = result.get(withErrorHandler: completion) else { return }
            SigningKeychain[self.context.team.id] = value
            completion(.success(value))
        }
    }

    private func revokeCreateSaveCertificate(
        certificate: DeveloperServicesCertificate,
        completion: @escaping (Result<SigningInfo, Swift.Error>) -> Void
    ) {
        let request = DeveloperServicesRevokeCertificateRequest(
            platform: context.platform,
            teamID: context.team.id,
            serialNumber: certificate.serialNumber
        )
        context.client.send(request) { result in
            guard result.get(withErrorHandler: completion) != nil else { return }
            self.createAndSaveCertificate(completion: completion)
        }
    }

    public func perform(completion: @escaping (Result<SigningInfo, Swift.Error>) -> Void) {
        let request = DeveloperServicesListCertificatesRequest(
            platform: context.platform, teamID: context.team.id
        )
        context.client.send(request) { result in
            guard let certificates = result.get(withErrorHandler: completion) else { return }

            guard let certificate = certificates.first(where: { $0.machineID == self.context.udid }) else {
                return self.createAndSaveCertificate(completion: completion)
            }

            guard let signingInfo = SigningKeychain[self.context.team.id],
                let serialNumber = try? signingInfo.certificate.serialNumber(),
                certificate.serialNumber.rawValue == serialNumber,
                certificate.expiry > Date()
                else { return self.revokeCreateSaveCertificate(
                    certificate: certificate, completion: completion
                ) }

            completion(.success(signingInfo))
        }
    }

}
