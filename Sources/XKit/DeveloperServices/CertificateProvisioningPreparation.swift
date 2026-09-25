import Foundation

public struct CertificateProvisioningNode: Sendable {
    public let relativePath: String
    public let originalBundleID: String
    public let finalBundleID: String
    public let requestedEntitlements: Entitlements

    public init(relativePath: String, originalBundleID: String, finalBundleID: String, requestedEntitlements: Entitlements) {
        self.relativePath = relativePath
        self.originalBundleID = originalBundleID
        self.finalBundleID = finalBundleID
        self.requestedEntitlements = requestedEntitlements
    }
}

public struct CertificateProvisioningNormalization: Sendable {
    public let entitlements: Entitlements
    public let removedEntitlementKeys: [String]
}

/// The same normalization feeds capability updates and the caller's snapshot.
public enum CertificateProvisioningPreparation {
    public static func mapBundleID(original: String, context: SigningContext) -> String {
        ProvisioningIdentifiers.identifier(fromSanitized: original, context: context)
    }

    public static func normalizeEntitlements(
        _ entitlements: Entitlements,
        isFreeTeam: Bool,
        teamID: String,
        originalBundleID: String,
        finalBundleID: String,
        context: SigningContext
    ) throws -> CertificateProvisioningNormalization {
        let original = try dictionary(entitlements)
        var result = entitlements
        if isFreeTeam {
            // Match the legacy free-team rule, including removal of unknown claims.
            result = try Entitlements(entitlements: entitlements.entitlements().filter {
                $0.anyCapability?.isFree != false
            })
        }
        let filtered = try dictionary(result)
        let removed = Set(original.keys).subtracting(filtered.keys).sorted()
        try result.update(teamID: .init(rawValue: teamID), bundleID: finalBundleID)
        try result.updateEntitlements { values in
            values.removeAll { $0 is GetTaskAllowEntitlement }
            values.append(GetTaskAllowEntitlement(rawValue: true))
        }
        var normalized = try dictionary(result)
        // Preserve shared keychain groups. Replace only the source app identifier
        // and its original team prefix; do not collapse all groups into one.
        if let groups = filtered[KeychainAccessGroupsEntitlement.identifier] as? [String] {
            let oldApplicationID = filtered[ApplicationIdentifierEntitlement.identifier] as? String
            let oldTeam = oldApplicationID.flatMap { value in
                value.hasSuffix("." + originalBundleID) ? String(value.dropLast(originalBundleID.count + 1)) : nil
            }
            normalized[KeychainAccessGroupsEntitlement.identifier] = groups.map { value in
                var group = value
                if group.hasPrefix("$(AppIdentifierPrefix)") {
                    group = teamID + "." + group.dropFirst("$(AppIdentifierPrefix)".count)
                }
                if let oldTeam, group.hasPrefix(oldTeam + ".") {
                    group = teamID + group.dropFirst(oldTeam.count)
                }
                if group == teamID + "." + originalBundleID {
                    group = teamID + "." + finalBundleID
                }
                return group
            }
        }
        if let groups = filtered[AppGroupEntitlement.identifier] as? [String] {
            normalized[AppGroupEntitlement.identifier] = groups.map { group in
                ProvisioningIdentifiers.groupID(
                    fromSanitized: ProvisioningIdentifiers.sanitize(groupID: .init(rawValue: group)),
                    context: context
                ).rawValue
            }
        }
        let data = try PropertyListSerialization.data(fromPropertyList: normalized, format: .xml, options: 0)
        return CertificateProvisioningNormalization(
            entitlements: try PropertyListDecoder().decode(Entitlements.self, from: data),
            removedEntitlementKeys: removed
        )
    }

    static func dictionary(_ entitlements: Entitlements) throws -> [String: Any] {
        let data = try PropertyListEncoder().encode(entitlements)
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CertificateProvisioningError.invalidRequest("Entitlements must be a dictionary.")
        }
        return result
    }
}
