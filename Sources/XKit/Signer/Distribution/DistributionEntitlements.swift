import Foundation

/// Computes the entitlements an app is signed with for distribution.
///
/// The profile is the source of truth for what the app is allowed to claim. The app (or the user, via
/// an entitlements file) may narrow what the profile grants, but asking for something the profile does not
/// allow is an error: App Store Connect and installd would reject the result anyway.
public enum DistributionEntitlements {

    /// Keys that always come from the profile, whatever the app asked for.
    private static let profileOwnedKeys: Set<String> = [
        "application-identifier",
        "com.apple.developer.team-identifier",
        "get-task-allow",
    ]

    /// Granted by the profile and claimed whether or not the app asks for them (Xcode does the same).
    private static let alwaysClaimedKeys: Set<String> = ["beta-reports-active"]

    public static func resolve(
        profile: DistributionProfile,
        bundleID: String,
        requested: Entitlements?
    ) throws -> Entitlements {
        let granted = try dictionary(of: profile.digest.entitlements)
        let requested = try requested.map(dictionary(of:)) ?? [:]

        let team = profile.digest.teamIdentifiers.first?.rawValue ?? ""
        let applicationIdentifier = "\(team).\(bundleID)"

        // Like Xcode, only claim what the app asked for. If we know nothing about the app
        // (it carries no entitlements of its own), fall back to what the profile grants.
        let appAsksForSomething = requested.keys.contains { !profileOwnedKeys.contains($0) }

        var result: [String: Any] = [:]
        for (key, grant) in granted where !profileOwnedKeys.contains(key) {
            if let request = requested[key] {
                guard permits(grant: grant, request: request) else {
                    throw DistributionSigningError.entitlementNotInProfile(key: key, profile: profile.name)
                }
                result[key] = request
            } else if !appAsksForSomething || alwaysClaimedKeys.contains(key) {
                if let value = narrow(key: key, grant: grant, applicationIdentifier: applicationIdentifier) {
                    result[key] = value
                }
            }
        }

        for key in requested.keys where granted[key] == nil && !profileOwnedKeys.contains(key) {
            throw DistributionSigningError.entitlementNotInProfile(key: key, profile: profile.name)
        }

        // a wildcard profile has `<team>.*`: the signed entitlement must name the actual app
        result["application-identifier"] = applicationIdentifier
        // distribution builds explicitly opt out of debugging, as Xcode's do
        result["get-task-allow"] = false
        result["com.apple.developer.team-identifier"] = team

        return try entitlements(from: result)
    }

    /// Resolves a wildcard grant to a concrete value, or `nil` if there is no sensible one to claim.
    private static func narrow(key: String, grant: Any, applicationIdentifier: String) -> Any? {
        switch grant {
        case let string as String:
            return string == "*" ? nil : string
        case let strings as [String]:
            let concrete = strings.compactMap { entry -> String? in
                guard entry.hasSuffix("*") else { return entry }
                // keychain groups are commonly granted as `<team>.*`, which means "this app's group"
                return key == "keychain-access-groups" ? applicationIdentifier : nil
            }
            var seen = Set<String>()
            let unique = concrete.filter { seen.insert($0).inserted }
            return unique.isEmpty ? nil : unique
        default:
            return grant
        }
    }

    static func permits(grant: Any, request: Any) -> Bool {
        switch (grant, request) {
        case let (grant as [String], request as [String]):
            return request.allSatisfy { item in
                grant.contains { $0 == item || ($0.hasSuffix("*") && item.hasPrefix(String($0.dropLast()))) }
            }
        // Apple issues some grants as a plain string where the app asks for an array, such as
        // `com.apple.developer.associated-domains`, granted as `*` in App Store profiles
        case let (grant as String, request as [String]):
            return permits(grant: [grant], request: request)
        case let (grant as [String], request as String):
            return permits(grant: grant, request: [request])
        case let (grant as String, request as String):
            return grant == request || (grant.hasSuffix("*") && request.hasPrefix(String(grant.dropLast())))
        case let (grant as Bool, request as Bool):
            return grant || !request
        default:
            return (grant as? NSObject)?.isEqual(request) ?? false
        }
    }

    // MARK: - Entitlements <-> plist dictionary

    static func dictionary(of entitlements: Entitlements) throws -> [String: Any] {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(entitlements)
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
    }

    static func entitlements(from dictionary: [String: Any]) throws -> Entitlements {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        return try PropertyListDecoder().decode(Entitlements.self, from: data)
    }

    /// Parses the entitlements plist embedded in a code signature, as returned by `Signer.analyze`.
    public static func parse(plist data: Data) -> Entitlements? {
        guard !data.isEmpty else { return nil }
        return try? PropertyListDecoder().decode(Entitlements.self, from: data)
    }

}
