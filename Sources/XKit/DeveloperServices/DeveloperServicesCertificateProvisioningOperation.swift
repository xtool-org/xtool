import Foundation
import DeveloperAPI

public struct CertificateProvisioningProfile: Sendable {
    public let resourceID: String
    public let name: String
    public let data: Data

    public init(resourceID: String, name: String, data: Data) {
        self.resourceID = resourceID
        self.name = name
        self.data = data
    }
}

public struct CertificateProvisioningResult: Sendable {
    public let node: CertificateProvisioningNode
    public let profileResourceID: String
    public let profileName: String
    public let profileData: Data
    public let entitlements: Entitlements
    public let removedEntitlementKeys: [String]
}

public struct CertificateProvisioningResponse: Sendable {
    public let isFreeTeam: Bool
    public let certificateResourceID: String
    public let nodes: [CertificateProvisioningResult]
}

/// Injectable boundary for tests. There is deliberately no delete-profile,
/// create-certificate, revoke-certificate, or private-key operation here.
public protocol CertificateProvisioningServing: Sendable {
    func team() async throws -> (teamID: String?, isFree: Bool)
    func certificates() async throws -> [DeveloperServicesCertificate]
    func registerDevice() async throws
    func prepareApp(_ node: CertificateProvisioningNode) async throws -> String
    func createProfile(bundleResourceID: String, bundleID: String, certificateResourceID: String) async throws -> CertificateProvisioningProfile
}

/// Cold provisioning with a caller-selected public certificate and explicit graph.
/// The caller validates the returned CMS, profile authorization, and shared state
/// before saving a snapshot. This operation never deletes an existing profile.
public struct DeveloperServicesCertificateProvisioningOperation: Sendable {
    public let context: SigningContext
    public let certificate: ProvisioningCertificate
    public let nodes: [CertificateProvisioningNode]
    private let service: any CertificateProvisioningServing
    private let apiCallObserver: @Sendable (String) -> Void
    private let status: @Sendable (String) -> Void

    public init(
        context: SigningContext,
        certificate: ProvisioningCertificate,
        nodes: [CertificateProvisioningNode],
        apiCallObserver: @escaping @Sendable (String) -> Void = { _ in },
        status: @escaping @Sendable (String) -> Void = { _ in },
        service: (any CertificateProvisioningServing)? = nil
    ) {
        self.context = context
        self.certificate = certificate
        self.nodes = nodes
        self.apiCallObserver = apiCallObserver
        self.status = status
        self.service = service ?? CertificateProvisioningService(context: context)
    }

    /// Read-only resource discovery for deterministic local-identity selection.
    /// This inherits ProvisioningAPICallObserver's task-local scope.
    public static func availableCertificates(context: SigningContext) async throws -> [DeveloperServicesCertificate] {
        do {
            return try await ProvisioningAPICallObserver.$suppressResponseBodies.withValue(true) {
                try await CertificateProvisioningService(context: context).certificates()
            }
        } catch {
            throw Self.safeError(error)
        }
    }

    public func perform() async throws -> CertificateProvisioningResponse {
        do {
            return try await ProvisioningAPICallObserver.$suppressResponseBodies.withValue(true) {
                try await ProvisioningAPICallObserver.$observer.withValue(apiCallObserver) {
                    try await provision()
                }
            }
        } catch {
            throw Self.safeError(error)
        }
    }

    private static func safeError(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled {
            return CancellationError()
        }
        if error is CertificateProvisioningError || error is DeveloperServicesFetchProfileOperation.Errors || error is DeveloperServicesAddDeviceOperation.Errors {
            return error
        }
        // OpenAPI ClientError can include authentication headers and raw bodies.
        // Keep these diagnostic objects inside the provisioning boundary.
        return CertificateProvisioningError.requestFailed
    }

    private func provision() async throws -> CertificateProvisioningResponse {
        try Task.checkCancellation()
        try certificate.validate(now: Date())
        guard let device = context.targetDevice, !device.udid.isEmpty,
              !nodes.isEmpty,
              Set(nodes.map(\.relativePath)).count == nodes.count,
              Set(nodes.map(\.finalBundleID)).count == nodes.count else {
            throw CertificateProvisioningError.invalidRequest("Specify one device and unique bundle paths and identifiers.")
        }
        for node in nodes {
            guard !node.originalBundleID.isEmpty,
                  !node.finalBundleID.isEmpty,
                  !node.finalBundleID.contains("*"),
                  node.relativePath == "." || (!node.relativePath.isEmpty && !node.relativePath.hasPrefix("/") && !node.relativePath.split(separator: "/").contains("..")) else {
                throw CertificateProvisioningError.invalidRequest("A bundle path or identifier is invalid.")
            }
            let parent = nodes.filter {
                $0.relativePath != node.relativePath &&
                    ($0.relativePath == "." || node.relativePath.hasPrefix($0.relativePath + "/"))
            }.max { $0.relativePath.count < $1.relativePath.count }
            if let parent, !node.finalBundleID.hasPrefix(parent.finalBundleID + ".") {
                throw CertificateProvisioningError.invalidRequest("A child identifier does not extend its parent identifier.")
            }
        }
        let team = try await service.team()
        if let teamID = team.teamID, teamID != certificate.teamID {
            throw CertificateProvisioningError.invalidRequest("The authenticated team differs from the certificate team.")
        }
        let certificateID = try certificate.resolveResourceID(in: await service.certificates())
        var prepared: [(CertificateProvisioningNode, [String])] = []
        for node in nodes.sorted(by: { $0.relativePath < $1.relativePath }) {
            let normalized = try CertificateProvisioningPreparation.normalizeEntitlements(
                node.requestedEntitlements,
                isFreeTeam: team.isFree,
                teamID: certificate.teamID,
                originalBundleID: node.originalBundleID,
                finalBundleID: node.finalBundleID,
                context: context
            )
            prepared.append((CertificateProvisioningNode(
                relativePath: node.relativePath,
                originalBundleID: node.originalBundleID,
                finalBundleID: node.finalBundleID,
                requestedEntitlements: normalized.entitlements
            ), normalized.removedEntitlementKeys))
        }
        status("Registering the target device for certificate-only provisioning.")
        do {
            try await service.registerDevice()
        } catch {
            try Task.checkCancellation()
            guard Self.registrationCanPropagate(error) else {
                throw error
            }
            status("Device registration is pending. Profile creation will retry.")
        }
        // Prepare the whole supplied graph first. Shared capabilities must be
        // settled before any replacement profile is created.
        var applications: [(CertificateProvisioningNode, [String], String)] = []
        for (node, removed) in prepared {
            try Task.checkCancellation()
            let resourceID = try await service.prepareApp(node)
            applications.append((node, removed, resourceID))
        }
        var result: [CertificateProvisioningResult] = []
        for (node, removed, applicationID) in applications {
            try Task.checkCancellation()
            let profile = try await createProfileWithRetry(node: node, applicationID: applicationID, certificateID: certificateID)
            result.append(CertificateProvisioningResult(
                node: node,
                profileResourceID: profile.resourceID,
                profileName: profile.name,
                profileData: profile.data,
                entitlements: node.requestedEntitlements,
                removedEntitlementKeys: removed
            ))
        }
        return CertificateProvisioningResponse(isFreeTeam: team.isFree, certificateResourceID: certificateID, nodes: result)
    }

    private func createProfileWithRetry(node: CertificateProvisioningNode, applicationID: String, certificateID: String) async throws -> CertificateProvisioningProfile {
        for attempt in 1...4 {
            try Task.checkCancellation()
            do {
                return try await service.createProfile(bundleResourceID: applicationID, bundleID: node.finalBundleID, certificateResourceID: certificateID)
            } catch {
                try Task.checkCancellation()
                guard attempt < 4, Self.shouldRetryProfile(error) else {
                    throw error
                }
                status("Waiting for device and App ID registration to propagate (attempt \(attempt + 1)/4).")
                do {
                    try await service.registerDevice()
                } catch {
                    try Task.checkCancellation()
                }
                try await Task.sleep(for: .seconds(Double(attempt)))
            }
        }
        throw CertificateProvisioningError.invalidProfileResponse
    }

    private static func shouldRetryProfile(_ error: any Error) -> Bool {
        if let error = error as? DeveloperServicesFetchProfileOperation.Errors {
            switch error {
            case .noRegisteredDevices, .bundleIDNotFound:
                return true
            default:
                return false
            }
        }
        let message = String(describing: error).lowercased()
        return message.contains("no current") && message.contains("devices") && message.contains("ios")
    }

    private static func registrationCanPropagate(_ error: any Error) -> Bool {
        if error is DeveloperServicesAddDeviceOperation.Errors {
            return true
        }
        let message = String(describing: error).lowercased()
        return message.contains("devices_createinstance")
            || message.contains("middleware of type 'developerapixcodeauthmiddleware'")
            || message.contains("client encountered an error invoking the operation")
            || message.contains("could not connect to the server")
            || message.contains("isn’t in the correct format")
            || message.contains("isn't in the correct format")
    }
}

struct CertificateProvisioningService: CertificateProvisioningServing {
    let context: SigningContext

    func team() async throws -> (teamID: String?, isFree: Bool) {
        let team = try await context.auth.team()
        if case .xcode(let auth) = context.auth {
            guard team?.id == auth.teamID, team?.status.lowercased() == "active" else {
                throw CertificateProvisioningError.invalidRequest("The authenticated team is unavailable.")
            }
        }
        return (team?.id.rawValue, team?.isFree == true)
    }

    func certificates() async throws -> [DeveloperServicesCertificate] {
        let pages = DeveloperAPIPages {
            try await context.developerAPIClient.certificatesGetCollection(query: .init(
                filter_lbrack_certificateType_rbrack_: [.development, .iosDevelopment],
                fields_lbrack_certificates_rbrack_: [.certificateType, .expirationDate, .certificateContent, .activated]
            )).ok.body.json
        } next: {
            $0.links.next
        }
        var result: [DeveloperServicesCertificate] = []
        for try await page in pages {
            result += page.data
        }
        try Task.checkCancellation()
        return result
    }

    func registerDevice() async throws {
        try await DeveloperServicesAddDeviceOperation(context: context, platform: .iOS).perform()
    }

    func prepareApp(_ node: CertificateProvisioningNode) async throws -> String {
        let groups = try node.requestedEntitlements.entitlements().first(where: { $0 is AppGroupEntitlement }) as? AppGroupEntitlement
        if let groups, !groups.rawValue.isEmpty, case .appStoreConnect = context.auth {
            throw CertificateProvisioningError.unsupportedAppGroupAuthentication
        }
        let app = try await DeveloperServicesUpsertAppOperation(
            context: context,
            originalBundleID: node.originalBundleID,
            newBundleID: node.finalBundleID,
            entitlements: node.requestedEntitlements,
            platform: .iOS
        ).perform()
        if let groups, !groups.rawValue.isEmpty {
            guard let operation = DeveloperServicesAssignAppGroupsOperation(
                context: context,
                groupIDs: groups.rawValue,
                appID: app,
                platform: .iOS,
                preserveExactGroupIDs: true
            ) else {
                throw CertificateProvisioningError.unsupportedAppGroupAuthentication
            }
            let assigned = try await operation.perform()
            guard Set(assigned) == Set(groups.rawValue) else {
                throw CertificateProvisioningError.invalidRequest("The assigned shared groups differ from the requested groups.")
            }
        }
        return app.id
    }

    func createProfile(bundleResourceID: String, bundleID: String, certificateResourceID: String) async throws -> CertificateProvisioningProfile {
        guard let deviceUDID = context.targetDevice?.udid.uppercased() else {
            throw CertificateProvisioningError.invalidRequest("The target device is missing.")
        }
        let pages = DeveloperAPIPages {
            try await context.developerAPIClient.devicesGetCollection().ok.body.json
        } next: {
            $0.links.next
        }
        var devices: [Components.Schemas.Device] = []
        for try await page in pages {
            devices += page.data.filter {
                $0.attributes?.status?.value1 == .enabled && $0.attributes?.udid?.uppercased() == deviceUDID
            }
        }
        try Task.checkCancellation()
        guard devices.count == 1, let device = devices.first else {
            throw DeveloperServicesFetchProfileOperation.Errors.noRegisteredDevices("iOS")
        }
        let name = "Xogot development \(bundleID) \(UUID().uuidString)"
        let response = try await context.developerAPIClient.profilesCreateInstance(body: .json(Self.profileRequest(
            name: name,
            bundleResourceID: bundleResourceID,
            certificateResourceID: certificateResourceID,
            deviceResourceID: device.id
        )))
        let profile: Components.Schemas.Profile
        do {
            profile = try response.created.body.json.data
        } catch {
            let message = String(describing: response).lowercased()
            if message.contains("limit") || message.contains("maximum") || message.contains("too many") {
                throw CertificateProvisioningError.profileLimitRequiresDecision(bundleID: bundleID)
            }
            if message.contains("notfound") || message.contains("not found") {
                throw DeveloperServicesFetchProfileOperation.Errors.bundleIDNotFound(bundleID)
            }
            throw error
        }
        guard !profile.id.isEmpty,
              let returnedName = profile.attributes?.name, returnedName == name,
              profile.attributes?.profileState?.value1 == .active,
              let content = profile.attributes?.profileContent,
              let data = Data(base64Encoded: content), !data.isEmpty else {
            throw CertificateProvisioningError.invalidProfileResponse
        }
        // Check that Apple returned a parseable container. Full CMS trust and
        // entitlement authorization are the caller's validation boundary.
        _ = try Mobileprovision(data: data)
        return CertificateProvisioningProfile(resourceID: profile.id, name: returnedName, data: data)
    }

    static func profileRequest(name: String, bundleResourceID: String, certificateResourceID: String, deviceResourceID: String) -> Components.Schemas.ProfileCreateRequest {
        .init(data: .init(
            _type: .profiles,
            attributes: .init(name: name, profileType: .init(.iosAppDevelopment)),
            relationships: .init(
                bundleId: .init(data: .init(_type: .bundleIds, id: bundleResourceID)),
                devices: .init(data: [.init(_type: .devices, id: deviceResourceID)]),
                certificates: .init(data: [.init(_type: .certificates, id: certificateResourceID)])
            )
        ))
    }
}
