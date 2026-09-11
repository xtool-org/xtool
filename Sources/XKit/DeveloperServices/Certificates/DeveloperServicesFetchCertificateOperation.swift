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
import CXKit
#if canImport(Security)
import Security
#endif

@_silgen_name("xtl_pkcs12_copy_private_key_pem")
private func xtl_pkcs12_copy_private_key_pem_native(
    _ p12Data: UnsafeRawPointer,
    _ p12Length: Int,
    _ password: UnsafePointer<CChar>?,
    _ pemLength: UnsafeMutablePointer<Int>
) -> UnsafeMutableRawPointer?

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
    @Dependency(\.keyValueStorage) var keyValueStorage

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

    private func loadLocalSigningInfo(
        matching certificates: [DeveloperServicesCertificate]
    ) -> SigningInfo? {
#if canImport(Security)
        let storedPath = try? keyValueStorage.string(forKey: "XTLSavedSigningP12Path")
        let candidates = [storedPath]
            .compactMap { $0 }
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        guard let p12URL = candidates.first,
              let p12Data = try? Data(contentsOf: p12URL)
        else {
            return nil
        }

        let password = (try? keyValueStorage.string(forKey: "XTLSavedSigningP12Password"))
            ?? ""

        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var importedItems: CFArray?
        let importStatus = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &importedItems)
        guard importStatus == errSecSuccess,
              let importedItems,
              let firstItem = (importedItems as NSArray).firstObject as? NSDictionary,
              let identityAny = firstItem[kSecImportItemIdentity as String]
        else {
            return nil
        }
        let identity = identityAny as! SecIdentity

        var certificateRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificateRef) == errSecSuccess,
              let certificateRef
        else {
            return nil
        }

        var privateKeyRef: SecKey?
        let privateKeyPEM: String
        if SecIdentityCopyPrivateKey(identity, &privateKeyRef) == errSecSuccess,
           let privateKeyRef,
           let privateKeyBytes = SecKeyCopyExternalRepresentation(privateKeyRef, nil) as Data?
        {
            privateKeyPEM = Self.pem(body: privateKeyBytes, header: "RSA PRIVATE KEY")
        } else if let pem = Self.extractPrivateKeyPEMWithNativePKCS12(p12Data: p12Data, password: password) {
            privateKeyPEM = pem
        } else {
            return nil
        }

        let certData = SecCertificateCopyData(certificateRef) as Data
        guard let certificate = try? Certificate(data: certData) else {
            return nil
        }

        let serial = certificate.serialNumber()
        let normalizedSerial = Self.normalizeSerialNumber(serial)
        guard let matchingCertificate = certificates.first(where: {
            Self.normalizeSerialNumber($0.attributes?.serialNumber) == normalizedSerial
        }),
              let expirationDate = matchingCertificate.attributes?.expirationDate,
              expirationDate > Date()
        else {
            return nil
        }

        let signingInfo = SigningInfo(
            privateKey: .init(data: Data(privateKeyPEM.utf8)),
            certificate: certificate
        )
        return signingInfo
#else
        _ = certificates
        return nil
#endif
    }

    private static func pem(body: Data, header: String) -> String {
        let base64 = body.base64EncodedString()
        var lines: [String] = []
        lines.reserveCapacity((base64.count / 64) + 2)
        var index = base64.startIndex
        while index < base64.endIndex {
            let nextIndex = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<nextIndex]))
            index = nextIndex
        }
        return "-----BEGIN \(header)-----\n\(lines.joined(separator: "\\n"))\n-----END \(header)-----\n"
    }

    private static func extractPrivateKeyPEMWithNativePKCS12(p12Data: Data, password: String) -> String? {
        let passwordCString = password.cString(using: .utf8) ?? [0]
        return p12Data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> String? in
            guard let base = bytes.baseAddress else {
                return nil
            }

            return passwordCString.withUnsafeBufferPointer { passwordBuffer in
                var pemLength = 0
                guard let pemPointer = xtl_pkcs12_copy_private_key_pem_native(
                    base,
                    bytes.count,
                    passwordBuffer.baseAddress,
                    &pemLength
                ), pemLength > 0 else {
                    return nil
                }

                let pemData = Data(bytesNoCopy: pemPointer, count: pemLength, deallocator: .free)
                return String(data: pemData, encoding: .utf8)
            }
        }
    }

    private static func normalizeSerialNumber(_ serial: String?) -> String {
        let upper = (serial ?? "").uppercased()
        let trimmed = upper.drop { $0 == "0" }
        return String(trimmed)
    }

    public func perform() async throws -> SigningInfo {
        let certificates = try await context.developerAPIClient.certificatesGetCollection().ok.body.json.data

        guard let signingInfo = signingInfoManager[self.context.auth.identityID] else {
            if let signingInfo = loadLocalSigningInfo(matching: certificates) {
                signingInfoManager[self.context.auth.identityID] = signingInfo
                return signingInfo
            }
            return try await self.replaceCertificates(certificates, requireConfirmation: true)
        }

        let knownSerialNumber = signingInfo.certificate.serialNumber()
        guard let certificate = certificates.first(where: { $0.attributes?.serialNumber == knownSerialNumber }) else {
            if let signingInfo = loadLocalSigningInfo(matching: certificates) {
                signingInfoManager[self.context.auth.identityID] = signingInfo
                return signingInfo
            }
            // we need to revoke existing certs, otherwise it doesn't always let us make a new one
            return try await self.replaceCertificates(certificates, requireConfirmation: true)
        }

        if let date = certificate.attributes?.expirationDate, date > Date() {
            return signingInfo
        } else {
            if let signingInfo = loadLocalSigningInfo(matching: certificates) {
                signingInfoManager[self.context.auth.identityID] = signingInfo
                return signingInfo
            }
            // we have a certificate for this machine but it's not usable
            return try await self.replaceCertificates(
                [certificate],
                requireConfirmation: false
            )
        }
    }

}
