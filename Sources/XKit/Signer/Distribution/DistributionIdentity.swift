import Foundation
import CXKit

/// A certificate and private key supplied by the user (typically an Apple Distribution identity
/// exported as a `.p12`). Nothing is created or revoked on Apple's side when using this.
public struct DistributionIdentity: Sendable {

    public let certificate: Certificate
    public let privateKey: PrivateKey

    public init(certificate: Certificate, privateKey: PrivateKey) {
        self.certificate = certificate
        self.privateKey = privateKey
    }

    public init(p12: Data, password: String) throws {
        var certDER: UnsafeMutableRawPointer?
        var certLength = 0
        var keyPEM: UnsafeMutableRawPointer?
        var keyLength = 0

        let status = p12.withUnsafeBytes { buffer in
            // an empty Data has no base address; OpenSSL then fails to parse it, which is the right outcome
            pkcs12_identity_extract(
                buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, buffer.count,
                password,
                &certDER, &certLength,
                &keyPEM, &keyLength
            )
        }

        switch status {
        case PKCS12_IDENTITY_OK:
            break
        case PKCS12_IDENTITY_BAD_PASSWORD:
            throw DistributionSigningError.wrongP12Password
        case PKCS12_IDENTITY_MISSING_CONTENT:
            throw DistributionSigningError.p12MissingContent
        default:
            throw DistributionSigningError.invalidP12
        }
        guard let certDER, let keyPEM else { throw DistributionSigningError.invalidP12 }

        let certData = Data(bytesNoCopy: certDER, count: certLength, deallocator: .free)
        let keyData = Data(bytesNoCopy: keyPEM, count: keyLength, deallocator: .free)
        self.init(certificate: try Certificate(data: certData), privateKey: PrivateKey(data: keyData))
    }

    public init(p12 url: URL, password: String) throws {
        try self.init(p12: Data(contentsOf: url), password: password)
    }

    /// Checks that the certificate is a usable distribution certificate.
    public func validate(now: Date = Date()) throws {
        let name = try certificate.developerIdentity()
        guard try certificate.isDistribution() else {
            throw DistributionSigningError.notADistributionCertificate(name)
        }
        guard certificate.expirationDate > now else {
            throw DistributionSigningError.certificateExpired(name, certificate.expirationDate)
        }
    }

}
