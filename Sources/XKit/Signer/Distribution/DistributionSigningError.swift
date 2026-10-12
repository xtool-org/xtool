import Foundation

public enum DistributionSigningError: LocalizedError, Equatable {
    case invalidP12
    case wrongP12Password
    case p12MissingContent
    case notADistributionCertificate(String)
    case certificateExpired(String, Date)
    case invalidProfile(String)
    case notADistributionProfile(profile: String)
    case profileExpired(profile: String, Date)
    case profileWrongPlatform(profile: String, [String])
    case profileTeamMismatch(profile: String, certificateTeam: String, profileTeams: [String])
    case certificateNotInProfile(profile: String, certificate: String)
    case noMatchingProfile(bundleID: String)
    case entitlementNotInProfile(key: String, profile: String)
    case invalidApp(String)
    case extensionsNotSupported([String])

    public var errorDescription: String? {
        switch self {
        case .invalidP12:
            "The .p12 file could not be read. Make sure it is a PKCS#12 archive."
        case .wrongP12Password:
            "The .p12 password is incorrect."
        case .p12MissingContent:
            "The .p12 file must contain both a certificate and its private key."
        case .notADistributionCertificate(let name):
            "'\(name)' is not a distribution certificate. Export an Apple Distribution identity instead."
        case .certificateExpired(let name, let date):
            "The certificate '\(name)' expired on \(date.formatted(.iso8601.year().month().day()))."
        case .invalidProfile(let path):
            "'\(path)' is not a valid provisioning profile."
        case .notADistributionProfile(let profile):
            "The profile '\(profile)' is a development profile. "
                + "Use an App Store or Ad Hoc profile to sign for distribution."
        case .profileExpired(let profile, let date):
            "The profile '\(profile)' expired on \(date.formatted(.iso8601.year().month().day()))."
        case .profileWrongPlatform(let profile, let platforms):
            "The profile '\(profile)' is for \(platforms.joined(separator: ", ")), not iOS."
        case .profileTeamMismatch(let profile, let certificateTeam, let profileTeams):
            "The profile '\(profile)' belongs to team \(profileTeams.joined(separator: ", ")), "
                + "but the certificate belongs to team \(certificateTeam)."
        case .certificateNotInProfile(let profile, let certificate):
            "The profile '\(profile)' does not include the certificate '\(certificate)'. "
                + "Regenerate the profile with this certificate selected."
        case .noMatchingProfile(let bundleID):
            "None of the provided profiles matches the bundle ID '\(bundleID)'."
        case .entitlementNotInProfile(let key, let profile):
            "The entitlement '\(key)' is requested but not allowed by the profile '\(profile)'."
        case .invalidApp(let reason):
            "Invalid app: \(reason)"
        case .extensionsNotSupported(let bundleIDs):
            "Signing app extensions for distribution is not supported yet (\(bundleIDs.joined(separator: ", "))). "
                + "The signer applies a single entitlements set to the whole bundle (see #131)."
        }
    }
}
