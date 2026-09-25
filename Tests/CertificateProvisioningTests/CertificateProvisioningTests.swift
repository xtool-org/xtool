import Foundation
import Crypto
import X509
import DeveloperAPI
import SignerSupport
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import XKit

private let registerTestSigner: Void = {
    add_signer("CertificateProvisioningTests", { _, _, _, _, _, _, _, _, _, exception in
        exception.initialize(to: strdup("Signing is forbidden in provisioning tests"))
        return 1
    }, { _, _, exception in
        exception.initialize(to: strdup("Executable analysis is forbidden in provisioning tests"))
        return nil
    })
}()

struct CertificateProvisioningTests {
    @Test func exactCertificateIgnoresMatchingSerialWithDifferentDER() throws {
        let fixture = try Fixture()
        let other = try Fixture()
        let resource = fixture.resource(id: "selected")
        var decoy = other.resource(id: "same-serial")
        decoy.attributes?.serialNumber = resource.attributes?.serialNumber
        #expect(try fixture.certificate.resolveResourceID(in: [decoy, resource]) == "selected")
        #expect(throws: (any Error).self) {
            try fixture.certificate.resolveResourceID(in: [decoy])
        }
    }

    @Test func ambiguousInactiveExpiredWrongTypeOrWrongTeamCertificatesFail() throws {
        let fixture = try Fixture()
        #expect(throws: (any Error).self) {
            try fixture.certificate.resolveResourceID(in: [fixture.resource(id: "a"), fixture.resource(id: "b")])
        }
        var inactive = fixture.resource(id: "inactive")
        inactive.attributes?.activated = false
        var expired = fixture.resource(id: "expired")
        expired.attributes?.expirationDate = Date(timeIntervalSince1970: 1)
        var distribution = fixture.resource(id: "distribution")
        distribution.attributes?.certificateType = .init(.distribution)
        for resource in [inactive, expired, distribution] {
            #expect(throws: (any Error).self) {
                try fixture.certificate.resolveResourceID(in: [resource])
            }
        }
        let wrongTeam = ProvisioningCertificate(certificateDER: fixture.certificate.certificateDER, teamID: "OTHER", certificateSHA1: fixture.certificate.certificateSHA1)
        #expect(throws: (any Error).self) {
            try wrongTeam.resolveResourceID(in: [fixture.resource(id: "selected")])
        }
        let wrongDigest = ProvisioningCertificate(certificateDER: fixture.certificate.certificateDER, teamID: "TEAM", certificateSHA1: String(repeating: "0", count: 40))
        #expect(throws: (any Error).self) {
            try wrongDigest.resolveResourceID(in: [fixture.resource(id: "selected")])
        }
    }

    @Test func profileRequestContainsOnlyTheSelectedCertificateAndTargetDevice() throws {
        let request = CertificateProvisioningService.profileRequest(name: "new", bundleResourceID: "app", certificateResourceID: "exact-certificate", deviceResourceID: "exact-device")
        #expect(request.data.relationships.certificates.data.map(\.id) == ["exact-certificate"])
        #expect(request.data.relationships.devices?.data?.map(\.id) == ["exact-device"])
        #expect(request.data.relationships.bundleId.data.id == "app")
    }

    @Test func createsReplacementWithoutDeletingExistingProfilesAndPreparesWholeGraphFirst() async throws {
        let fixture = try Fixture()
        let context = try fixture.context()
        let nodes = try [fixture.node(path: ".", id: "com.example.game"), fixture.node(path: "PlugIns/Child.appex", id: "com.example.game.child")]
        let service = MockService(resources: [fixture.resource(id: "exact")])
        let result = try await DeveloperServicesCertificateProvisioningOperation(context: context, certificate: fixture.certificate, nodes: nodes, service: service).perform()
        #expect(result.certificateResourceID == "exact")
        #expect(result.nodes.count == 2)
        #expect(result.nodes.allSatisfy { $0.profileResourceID.hasPrefix("replacement-") })
        #expect(await service.existingProfile == Data("original profile".utf8))
        #expect(await service.events == ["team", "certificates", "register", "prepare:.", "prepare:PlugIns/Child.appex", "create:com.example.game:exact", "create:com.example.game.child:exact"])
    }

    @Test func profileLimitDoesNotDeleteOldProfileOrTryAnotherCertificate() async throws {
        let fixture = try Fixture()
        let service = MockService(resources: [fixture.resource(id: "exact")], failWithLimit: true)
        do {
            _ = try await DeveloperServicesCertificateProvisioningOperation(context: fixture.context(), certificate: fixture.certificate, nodes: [fixture.node(path: ".", id: "com.example.game")], service: service).perform()
            Issue.record("Expected an explicit profile-limit decision")
        } catch CertificateProvisioningError.profileLimitRequiresDecision(let bundleID) {
            #expect(bundleID == "com.example.game")
        }
        #expect(await service.existingProfile == Data("original profile".utf8))
        #expect(await service.events.filter { $0.hasPrefix("create:") }.count == 1)
    }

    @Test func noMatchingCertificateFailsBeforeDeviceOrAppMutation() async throws {
        let fixture = try Fixture()
        let service = MockService(resources: [])
        await #expect(throws: (any Error).self) {
            try await DeveloperServicesCertificateProvisioningOperation(context: fixture.context(), certificate: fixture.certificate, nodes: [fixture.node(path: ".", id: "com.example.game")], service: service).perform()
        }
        #expect(await service.events == ["team", "certificates"])
    }

    @Test func cancellationDoesNotCreateAProfile() async throws {
        let fixture = try Fixture()
        let service = MockService(resources: [fixture.resource(id: "exact")], cancelDuringPrepare: true)
        await #expect(throws: CancellationError.self) {
            try await DeveloperServicesCertificateProvisioningOperation(context: fixture.context(), certificate: fixture.certificate, nodes: [fixture.node(path: ".", id: "com.example.game")], service: service).perform()
        }
        #expect(await service.events.allSatisfy { !$0.hasPrefix("create:") })
        #expect(await service.existingProfile == Data("original profile".utf8))
    }

    @Test func devicePropagationRetriesTheSameCertificateWithoutReplacingEarlierProfiles() async throws {
        let fixture = try Fixture()
        let service = MockService(resources: [fixture.resource(id: "exact")], transientProfileFailures: 1)
        let response = try await DeveloperServicesCertificateProvisioningOperation(context: fixture.context(), certificate: fixture.certificate, nodes: [fixture.node(path: ".", id: "com.example.game")], service: service).perform()
        #expect(response.nodes.count == 1)
        #expect(await service.events.filter { $0.hasPrefix("create:") } == ["create:com.example.game:exact", "create:com.example.game:exact"])
        #expect(await service.events.filter { $0 == "register" }.count == 2)
        #expect(await service.existingProfile == Data("original profile".utf8))
    }

    @Test func mappingAndFreeTeamFilteringAreExplicitAndPaidUnknownClaimsSurvive() throws {
        let fixture = try Fixture()
        let context = try fixture.context()
        let requested = try fixture.entitlements([
            "com.example.unknown": true,
            "com.apple.security.application-groups": ["group.com.example.shared"],
            "application-identifier": "OLD.com.example.game",
            "keychain-access-groups": ["OLD.com.example.game", "OLD.shared"]
        ])
        let final = CertificateProvisioningPreparation.mapBundleID(original: "com.example.game", context: context)
        #expect(final == "XTL-TEAM.com.example.game")
        #expect(CertificateProvisioningPreparation.mapBundleID(original: final, context: context) == final)
        let paid = try CertificateProvisioningPreparation.normalizeEntitlements(requested, isFreeTeam: false, teamID: "TEAM", originalBundleID: "com.example.game", finalBundleID: final, context: context)
        let paidDictionary = try CertificateProvisioningPreparation.dictionary(paid.entitlements)
        #expect(paidDictionary["com.example.unknown"] as? Bool == true)
        #expect(paidDictionary["keychain-access-groups"] as? [String] == ["TEAM.\(final)", "TEAM.shared"])
        #expect(paidDictionary["com.apple.security.application-groups"] as? [String] == ["group.XTL-TEAM.com.example.shared"])
        #expect(paid.removedEntitlementKeys.isEmpty)
        let free = try CertificateProvisioningPreparation.normalizeEntitlements(requested, isFreeTeam: true, teamID: "TEAM", originalBundleID: "com.example.game", finalBundleID: final, context: context)
        #expect(Set(free.removedEntitlementKeys) == ["com.example.unknown", "com.apple.security.application-groups"])
    }

    @Test func observerCountsActualMiddlewareInvocationsAndRestoresScope() async throws {
        let count = Counter()
        let middleware = DeveloperServicesAPIObservationMiddleware()
        let request = HTTPRequest(method: .get, scheme: "https", authority: "example.invalid", path: "/v1/certificates")
        try await ProvisioningAPICallObserver.$observer.withValue({ _ in count.increment() }) {
            for _ in 0..<3 {
                _ = try await middleware.intercept(request, body: nil, baseURL: URL(string: "https://example.invalid")!, operationID: "certificatesGetCollection") { _, _, _ in
                    (HTTPResponse(status: .ok), nil)
                }
            }
        }
        #expect(count.value == 3)
        ProvisioningAPICallObserver.observer("outside-scope")
        #expect(count.value == 3)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.withLock { count }
    }
    func increment() {
        lock.withLock { count += 1 }
    }
}

private struct Fixture {
    let certificate: ProvisioningCertificate

    init() throws {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            OrganizationalUnitName("TEAM")
            CommonName("Apple Development: Test")
        }
        let certificate = try X509.Certificate(
            version: .v3,
            serialNumber: .init(bytes: [1]),
            publicKey: .init(key.publicKey),
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(86400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: .init {},
            issuerPrivateKey: .init(key)
        )
        let data = try XKit.Certificate(raw: certificate).data()
        self.certificate = ProvisioningCertificate(certificateDER: data, teamID: "TEAM", certificateSHA1: ProvisioningCertificate.sha1(data))
    }

    func resource(id: String) -> DeveloperServicesCertificate {
        .init(_type: .certificates, id: id, attributes: .init(
            certificateType: .init(.development),
            serialNumber: "01",
            expirationDate: Date().addingTimeInterval(86400),
            certificateContent: certificate.certificateDER.base64EncodedString(),
            activated: true
        ))
    }

    func context() throws -> SigningContext {
        _ = registerTestSigner
        return try SigningContext(auth: .xcode(.init(
            loginToken: .init(adsid: "test", token: "not-a-real-token", expiry: .distantFuture),
            teamID: .init(rawValue: "TEAM")
        )), targetDevice: .init(udid: "TARGET-UDID", name: "Fixture"))
    }

    func node(path: String, id: String) throws -> CertificateProvisioningNode {
        .init(relativePath: path, originalBundleID: id, finalBundleID: id, requestedEntitlements: try Entitlements(entitlements: []))
    }

    func entitlements(_ dictionary: [String: Any]) throws -> Entitlements {
        try PropertyListDecoder().decode(Entitlements.self, from: PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0))
    }
}

private actor MockService: CertificateProvisioningServing {
    let resources: [DeveloperServicesCertificate]
    let failWithLimit: Bool
    let cancelDuringPrepare: Bool
    var transientProfileFailures: Int
    let existingProfile = Data("original profile".utf8)
    var events: [String] = []

    init(resources: [DeveloperServicesCertificate], failWithLimit: Bool = false, cancelDuringPrepare: Bool = false, transientProfileFailures: Int = 0) {
        self.resources = resources
        self.failWithLimit = failWithLimit
        self.cancelDuringPrepare = cancelDuringPrepare
        self.transientProfileFailures = transientProfileFailures
    }

    func team() -> (teamID: String?, isFree: Bool) {
        events.append("team")
        return ("TEAM", false)
    }

    func certificates() -> [DeveloperServicesCertificate] {
        events.append("certificates")
        return resources
    }

    func registerDevice() {
        events.append("register")
    }

    func prepareApp(_ node: CertificateProvisioningNode) throws -> String {
        events.append("prepare:" + node.relativePath)
        if cancelDuringPrepare {
            throw CancellationError()
        }
        return node.finalBundleID
    }

    func createProfile(bundleResourceID: String, bundleID: String, certificateResourceID: String) throws -> CertificateProvisioningProfile {
        events.append("create:\(bundleID):\(certificateResourceID)")
        if transientProfileFailures > 0 {
            transientProfileFailures -= 1
            throw DeveloperServicesFetchProfileOperation.Errors.noRegisteredDevices("iOS")
        }
        if failWithLimit {
            throw CertificateProvisioningError.profileLimitRequiresDecision(bundleID: bundleID)
        }
        return .init(resourceID: "replacement-" + bundleID, name: "Xogot replacement", data: Data("replacement profile".utf8))
    }
}
