import Foundation

/// A user-supplied App Store or Ad Hoc provisioning profile.
public struct DistributionProfile: Sendable {

    public let mobileprovision: Mobileprovision
    public let digest: Mobileprovision.Digest

    public init(mobileprovision: Mobileprovision) throws {
        self.mobileprovision = mobileprovision
        do {
            self.digest = try mobileprovision.digest()
        } catch {
            throw DistributionSigningError.invalidProfile("embedded profile")
        }
    }

    public init(data: Data) throws {
        try self.init(mobileprovision: try Mobileprovision(data: data))
    }

    public init(contentsOf url: URL) throws {
        let mobileprovision: Mobileprovision
        do {
            mobileprovision = try Mobileprovision(contentsOf: url)
        } catch {
            throw DistributionSigningError.invalidProfile(url.lastPathComponent)
        }
        do {
            self.digest = try mobileprovision.digest()
        } catch {
            throw DistributionSigningError.invalidProfile(url.lastPathComponent)
        }
        self.mobileprovision = mobileprovision
    }

    public var name: String { digest.name }

    /// The `application-identifier` entitlement, `<team>.<bundle id>` (the bundle ID may be a wildcard).
    public var applicationIdentifier: String? {
        (try? digest.entitlements.entitlements())?
            .compactMap { $0 as? ApplicationIdentifierEntitlement }
            .first?.rawValue
    }

    /// Whether this profile can sign an app with the given bundle ID.
    public func matches(bundleID: String) -> Bool {
        specificity(forBundleID: bundleID) != nil
    }

    /// `nil` if the profile doesn't match; otherwise larger values are more specific
    /// (an exact match beats a wildcard, a longer wildcard prefix beats a shorter one).
    func specificity(forBundleID bundleID: String) -> Int? {
        guard let appID = applicationIdentifier,
              let team = digest.teamIdentifiers.first?.rawValue,
              appID.hasPrefix(team + ".")
        else { return nil }
        let pattern = String(appID.dropFirst(team.count + 1))
        if pattern == bundleID { return Int.max }
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return bundleID.hasPrefix(prefix) ? prefix.count : nil
        }
        return nil
    }

    /// Verifies that the profile can be used to sign with `identity`.
    public func validate(for identity: DistributionIdentity, now: Date = Date()) throws {
        switch digest.kind {
        case .development:
            throw DistributionSigningError.notADistributionProfile(profile: name)
        case .appStore, .adHoc, .enterprise:
            break
        }
        guard digest.expirationDate > now else {
            throw DistributionSigningError.profileExpired(profile: name, digest.expirationDate)
        }
        guard digest.platforms.isEmpty || digest.platforms.contains("iOS") else {
            throw DistributionSigningError.profileWrongPlatform(profile: name, digest.platforms)
        }

        let certTeam = try identity.certificate.teamID()
        let profileTeams = digest.teamIdentifiers.map(\.rawValue)
        guard profileTeams.contains(certTeam) else {
            throw DistributionSigningError.profileTeamMismatch(
                profile: name,
                certificateTeam: certTeam,
                profileTeams: profileTeams
            )
        }

        let certData = try identity.certificate.data()
        guard try digest.certificates.contains(where: { try $0.data() == certData }) else {
            throw DistributionSigningError.certificateNotInProfile(
                profile: name,
                certificate: try identity.certificate.developerIdentity()
            )
        }
    }

}
