import Foundation
import Crypto
import DeveloperAPI

/// Public certificate bytes only. Provisioning never receives a key or SigningInfo.
public struct ProvisioningCertificate: Sendable, Equatable {
    public let certificateDER: Data
    public let teamID: String
    public let certificateSHA1: String

    public init(certificateDER: Data, teamID: String, certificateSHA1: String) {
        self.certificateDER = certificateDER
        self.teamID = teamID
        self.certificateSHA1 = certificateSHA1.uppercased()
    }

    public static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    func validate(now: Date) throws {
        let certificate = try Certificate(data: certificateDER)
        guard !teamID.isEmpty,
              Self.sha1(certificateDER) == certificateSHA1,
              try certificate.teamID() == teamID,
              certificate.raw.notValidBefore <= now,
              certificate.raw.notValidAfter > now else {
            throw CertificateProvisioningError.invalidCertificate
        }
    }

    /// Match public DER bytes and digest, never a serial number or display name.
    /// The caller must validate Apple trust locally before submitting this value.
    public func resolveResourceID(in resources: [DeveloperServicesCertificate], now: Date = Date()) throws -> String {
        try validate(now: now)
        let matches = resources.filter { resource in
            guard let attributes = resource.attributes,
                  attributes.certificateType?.value1 == .development || attributes.certificateType?.value1 == .iosDevelopment,
                  attributes.activated != false,
                  let expiration = attributes.expirationDate, expiration > now,
                  let content = attributes.certificateContent,
                  let data = Data(base64Encoded: content),
                  data == certificateDER,
                  Self.sha1(data) == certificateSHA1 else {
                return false
            }
            return !resource.id.isEmpty
        }
        guard matches.count == 1, let match = matches.first else {
            throw CertificateProvisioningError.certificateMatchCount(matches.count)
        }
        return match.id
    }
}

public enum CertificateProvisioningError: LocalizedError, Sendable {
    case invalidRequest(String)
    case invalidCertificate
    case certificateMatchCount(Int)
    case profileLimitRequiresDecision(bundleID: String)
    case invalidProfileResponse
    case requestFailed
    case unsupportedAppGroupAuthentication

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason):
            return "Certificate provisioning request is invalid: \(reason)"
        case .invalidCertificate:
            return "The public certificate does not match its team, digest, or validity dates."
        case .certificateMatchCount(let count):
            return "Expected one active Apple Development certificate resource with the selected DER and SHA-1; found \(count)."
        case .profileLimitRequiresDecision(let bundleID):
            return "Apple could not create a replacement profile for \(bundleID) because of a profile limit. No profile was deleted. Select an exact old profile to remove before retrying."
        case .requestFailed:
            return "Apple Developer services could not complete certificate-only provisioning. No certificate or existing profile was deleted."
        case .invalidProfileResponse:
            return "Apple returned an invalid development profile response."
        case .unsupportedAppGroupAuthentication:
            return "App group provisioning requires Xcode account authentication."
        }
    }
}
