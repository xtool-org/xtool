import Foundation

/// Brings the entitlements an app is about to be signed with in line with what its provisioning
/// profile actually grants.
///
/// installd rejects an app whose signature claims an entitlement the profile doesn't grant, with the
/// unhelpful `0xe8008015 A valid provisioning profile for this executable was not found`. The profile
/// is created through the API after the entitlements are computed, and it doesn't necessarily end up with
/// all of them (for instance, App Groups can't be managed with an App Store Connect API key). This
/// catches the difference before it reaches the device.
public enum EntitlementsReconciler {

    public enum Error: LocalizedError, CustomStringConvertible, Equatable {
        case appGroupsNotGranted(groups: [String], profile: String)
        case notGranted(key: String, profile: String)
        case valueNotGranted(key: String, profile: String)

        private var message: String {
            switch self {
            case .appGroupsNotGranted(let groups, let profile):
                "The provisioning profile '\(profile)' does not include the app groups "
                    + "\(groups.joined(separator: ", ")). App Groups can only be created when signed in with an "
                    + "Apple ID, not with an App Store Connect API key: run `xtool auth login --mode password`, "
                    + "or remove the com.apple.security.application-groups entitlement."
            case .notGranted(let key, let profile):
                "The app requests the entitlement '\(key)', which the provisioning profile '\(profile)' "
                    + "does not grant. Remove it from the app's entitlements, or enable the matching "
                    + "capability for this app ID."
            case .valueNotGranted(let key, let profile):
                "The value of the entitlement '\(key)' is not allowed by the provisioning profile '\(profile)'."
            }
        }

        // the CLI prints errors with string interpolation, which ignores `errorDescription`
        public var description: String { message }
        public var errorDescription: String? { message }
    }

    /// Entitlements only meaningful for a distribution build (an Xcode-exported or xtool-distribution-signed
    /// IPA carries them). A development profile never grants them, so re-signing for development drops them.
    private static let distributionOnlyKeys: Set<String> = [
        "beta-reports-active",
        "com.apple.developer.icloud-container-environment",
    ]

    public struct Result {
        public var entitlements: Entitlements
        /// Distribution-only entitlements that were dropped because the profile doesn't grant them
        public var removed: [String]
    }

    private static let appGroupsKey = AppGroupEntitlement.identifier
    private static let apsEnvironmentKey = APSEnvironmentEntitlement.identifier

    /// Entitlements that are derived from the profile and the bundle, never requested by the app
    private static let derivedKeys: Set<String> = [
        ApplicationIdentifierEntitlement.identifier,
        TeamIdentifierEntitlement.identifier,
        GetTaskAllowEntitlement.identifier,
        KeychainAccessGroupsEntitlement.identifier,
    ]

    private static let knownKeys: Set<String> = Set(
        EntitlementContainer.supportedTypes.compactMap { ($0 as? any Entitlement.Type)?.identifier }
    ).subtracting(derivedKeys)

    /// - Parameters:
    ///   - entitlements: What the app is going to be signed with.
    ///   - granted: The entitlements of the provisioning profile.
    /// - Returns: `entitlements`, with the values the profile dictates replaced and the distribution-only
    ///   entitlements it doesn't grant removed.
    /// - Throws: ``Error`` if the app claims something the profile doesn't grant.
    ///
    /// Only entitlements xtool knows how to provision are checked. Others are passed through
    /// untouched, since we can't tell whether the profile is expected to list them.
    public static func reconcile(
        _ entitlements: Entitlements,
        with granted: Entitlements,
        profileName: String
    ) throws -> Result {
        let grants = try granted.plistDictionary()
        var result = try entitlements.plistDictionary()

        let removed = distributionOnlyKeys.filter { result[$0] != nil && grants[$0] == nil }.sorted()
        removed.forEach { result[$0] = nil }

        for key in result.keys.sorted() where knownKeys.contains(key) {
            guard let request = result[key] else { continue }
            guard let grant = grants[key] else {
                throw key == appGroupsKey
                    ? Error.appGroupsNotGranted(groups: request as? [String] ?? [], profile: profileName)
                    : Error.notGranted(key: key, profile: profileName)
            }

            if key == apsEnvironmentKey {
                // a development profile only allows the sandbox push environment, whatever the
                // app was built with; Xcode makes the same substitution
                result[key] = grant
            } else if !permits(grant: grant, request: request) {
                if key == appGroupsKey {
                    // the profile may list the entitlement with no (or other) groups, which is
                    // what happens when groups can't be assigned
                    let missing = (request as? [String] ?? []).filter {
                        !permits(grant: grant, request: [$0])
                    }
                    throw Error.appGroupsNotGranted(groups: missing, profile: profileName)
                }
                throw Error.valueNotGranted(key: key, profile: profileName)
            }
        }

        return Result(entitlements: try Entitlements(plistDictionary: result), removed: removed)
    }

    /// Whether `grant` (a value from a profile, possibly with wildcards) allows `request`
    static func permits(grant: Any, request: Any) -> Bool {
        switch (grant, request) {
        case let (grant as [String], request as [String]):
            return request.allSatisfy { item in
                grant.contains { $0 == item || ($0.hasSuffix("*") && item.hasPrefix(String($0.dropLast()))) }
            }
        case let (grant as String, request as String):
            return grant == request || (grant.hasSuffix("*") && request.hasPrefix(String(grant.dropLast())))
        case let (grant as Bool, request as Bool):
            return grant || !request
        default:
            return (grant as? NSObject)?.isEqual(request) ?? false
        }
    }

}

extension Entitlements {

    init(plistDictionary: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plistDictionary, format: .xml, options: 0)
        self = try PropertyListDecoder().decode(Entitlements.self, from: data)
    }

    func plistDictionary() throws -> [String: Any] {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(self)
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
    }

}
