import Foundation
import DeveloperAPI

struct DeveloperServicesUpsertAppOperation: Sendable {
    let context: SigningContext
    let originalBundleID: String
    let newBundleID: String
    let entitlements: Entitlements
    let platform: ProvisioningPlatform

    func perform() async throws -> Components.Schemas.BundleId {
        let expectedPlatform = platform.bundleIDPlatform

        let pages = DeveloperAPIPages {
            try await context.developerAPIClient.bundleIdsGetCollection(query: .init(
                filter_lbrack_identifier_rbrack_: [newBundleID]
            )).ok.body.json
        } next: {
            $0.links.next
        }
        var matches: [Components.Schemas.BundleId] = []
        for try await page in pages {
            matches += page.data.filter { candidate in
                guard candidate.attributes?.identifier == newBundleID else {
                    return false
                }
                guard let value = candidate.attributes?.platform?.value1 else {
                    return true
                }
                switch expectedPlatform {
                case .ios:
                    return value == .ios || value == .universal
                case .macOs:
                    return value == .macOs || value == .universal
                case .universal:
                    return true
                }
            }
        }
        try Task.checkCancellation()
        guard matches.count <= 1 else {
            throw DeveloperServicesFetchProfileOperation.Errors.tooManyMatchingBundleIDs(newBundleID)
        }
        let existing = matches.first

        let appID: Components.Schemas.BundleId
        if let existing {
            appID = existing
        } else {
            let name = ProvisioningIdentifiers.appName(fromSanitized: originalBundleID)
            let createResponse = try await context.developerAPIClient.bundleIdsCreateInstance(
                body: .json(
                    .init(
                        data: .init(
                            _type: .bundleIds,
                            attributes: .init(
                                name: name,
                                platform: .init(platform.bundleIDPlatform),
                                identifier: newBundleID
                            )
                        )
                    )
                )
            )
            appID = try createResponse.created.body.json.data
        }

        let existingCapabilitiesList = try await context.developerAPIClient
            .bundleIdsBundleIdCapabilitiesGetToManyRelated(.init(path: .init(id: appID.id)))
            .ok.body.json.data
        let existingCapabilities = [Components.Schemas.CapabilityType: Components.Schemas.BundleIdCapability](
            existingCapabilitiesList.compactMap { cap in
                (cap.attributes?.capabilityType).map { ($0, cap) }
            },
            uniquingKeysWith: { $1 }
        )

        let wantedCapabilitiesList = try entitlements.entitlements().compactMap(\.anyCapability)
        let wantedCapabilities = [Components.Schemas.CapabilityType: [Components.Schemas.CapabilitySetting]](
            wantedCapabilitiesList.map { ($0.capabilityType, $0.settings ?? []) },
            uniquingKeysWith: { $1 }
        )

        for (typ, cap) in existingCapabilities {
            if let wantedSettings = wantedCapabilities[typ] {
                if wantedSettings != (cap.attributes?.settings ?? []) {
                    _ = try await context.developerAPIClient.bundleIdCapabilitiesUpdateInstance(
                        path: .init(id: cap.id),
                        body: .json(
                            .init(
                                data: .init(
                                    _type: .bundleIdCapabilities,
                                    id: cap.id,
                                    attributes: .init(
                                        capabilityType: typ,
                                        settings: wantedSettings
                                    )
                                )
                            )
                        )
                    )
                    .ok
                }
            } else {
                // DeveloperServices doesn't allow deleting these capabilities
                let requiredCapabilities: Set<Components.Schemas.CapabilityType.Value1Payload> = [.inAppPurchase]
                if let capType = cap.attributes?.capabilityType?.value1, !requiredCapabilities.contains(capType) {
                    _ = try await context.developerAPIClient
                        .bundleIdCapabilitiesDeleteInstance(path: .init(id: cap.id))
                        .noContent
                }
            }
        }
        for (typ, settings) in wantedCapabilities {
            guard existingCapabilities[typ] == nil else {
                continue
            }
            _ = try await context.developerAPIClient.bundleIdCapabilitiesCreateInstance(
                body: .json(.init(data: .init(
                    _type: .bundleIdCapabilities,
                    attributes: .init(
                        capabilityType: typ,
                        settings: settings
                    ),
                    relationships: .init(
                        bundleId: .init(
                            data: .init(
                                _type: .bundleIds,
                                id: appID.id
                            )
                        ),
                        // not public but required when using ds2 API
                        capability: .init(
                            data: .init(
                                _type: .capabilities,
                                id: typ
                            )
                        )
                    )
                )))
            )
            .created.body
        }

        return appID
    }
}
