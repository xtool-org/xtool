import Foundation
import Testing
import Crypto
import X509
import Dependencies
import OpenAPIRuntime
@testable import XKit

@Test(arguments: [SigningPlatform.iOS, .tvOS])
func profileRequestsUsePlatformAndAllDevicePages(platform: SigningPlatform) async throws {
    let client = ProfileTestClient(existingProfileType: "TVOS_APP_STORE")
    try await exerciseProfileRequest(platform: platform, client: client)
    let body = try #require(await client.createdBody)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    let data = try #require(json?["data"] as? [String: Any])
    let attributes = try #require(data["attributes"] as? [String: Any])
    #expect(attributes["profileType"] as? String == platform.developmentProfileType.rawValue)
    let relationships = try #require(data["relationships"] as? [String: Any])
    let devices = try #require(relationships["devices"] as? [String: Any])
    let ids = try #require(devices["data"] as? [[String: String]]).compactMap { $0["id"] }
    #expect(ids == (platform == .tvOS ? ["tv-1", "tv-2"] : ["phone"]))
    #expect(await client.deletedIDs.isEmpty)
}

@Test func renewalReplacesOnlyMatchingDevelopmentProfile() async throws {
    let client = ProfileTestClient(existingProfileType: "TVOS_APP_DEVELOPMENT")
    try await exerciseProfileRequest(platform: .tvOS, client: client)
    #expect(await client.deletedIDs == ["existing"])
}

private func exerciseProfileRequest(platform: SigningPlatform, client: ProfileTestClient) async throws {
    let key = P256.Signing.PrivateKey()
    let name = try DistinguishedName { CommonName("xtool tests") }
    let certificate = try X509.Certificate(
        version: .v3, serialNumber: .init(bytes: [1]), publicKey: .init(key.publicKey),
        notValidBefore: Date(), notValidAfter: Date() + 3600, issuer: name, subject: name,
        signatureAlgorithm: .ecdsaWithSHA256, extensions: .init(), issuerPrivateKey: .init(key)
    )
    let auth = DeveloperAPIAuthData.appStoreConnect(.init(id: "TEST", issuerID: "TEST", pem: key.pemRepresentation))
    try await withDependencies {
        $0.httpClient = client
    } operation: {
        do {
            _ = try await DeveloperServicesFetchProfileOperation(
                context: .init(auth: auth, platform: platform), bundleID: "com.example.app",
                signingInfo: .init(privateKey: .init(data: Data(key.pemRepresentation.utf8)),
                                   certificate: .init(raw: certificate))
            ).perform()
            Issue.record("The mock profile content must be rejected")
        } catch DeveloperServicesFetchProfileOperation.Errors.invalidProfileData {
            // The request completed; the mock deliberately does not contain an Apple-signed profile.
        }
    }
}

private actor ProfileTestClient: HTTPClientProtocol, ClientTransport {
    nonisolated var asOpenAPITransport: ClientTransport { self }
    let existingProfileType: String
    var createdBody: Data?
    var deletedIDs: [String] = []

    init(existingProfileType: String) { self.existingProfileType = existingProfileType }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL,
              operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let json: String
        var status = HTTPResponse.Status.ok
        switch operationID {
        case "bundleIds_getCollection":
            json = """
            {"data":[{"type":"bundleIds","id":"app","attributes":{"identifier":"com.example.app"},
            "relationships":{"profiles":{"data":[{"type":"profiles","id":"existing"}]}}}],
            "included":[{"type":"profiles","id":"existing","attributes":{"profileType":"\(existingProfileType)"}}],
            "links":{"self":"https://example.test/bundleIds"}}
            """
        case "certificates_getCollection":
            json = """
            {"data":[{"type":"certificates","id":"cert","attributes":{"serialNumber":"01"}}],
            "links":{"self":"https://example.test/certificates"}}
            """
        case "devices_getCollection":
            if request.path?.contains("cursor=") == true {
                json = """
                {"data":[{"type":"devices","id":"tv-2","attributes":{"deviceClass":"APPLE_TV"}}],
                "links":{"self":"https://example.test/devices"}}
                """
            } else {
                json = """
                {"data":[{"type":"devices","id":"phone","attributes":{"deviceClass":"IPHONE"}},
                {"type":"devices","id":"tv-1","attributes":{"deviceClass":"APPLE_TV"}},
                {"type":"devices","id":"future","attributes":{"deviceClass":"UNKNOWN_FUTURE_DEVICE"}}],
                "links":{"self":"https://example.test/devices",
                "next":"https://api.appstoreconnect.apple.com/v1/devices?cursor=next&limit=1"}}
                """
            }
        case "profiles_deleteInstance":
            deletedIDs.append("existing")
            return (HTTPResponse(status: .noContent), nil)
        case "profiles_createInstance":
            if let body { createdBody = try await Data(collecting: body, upTo: 1_000_000) }
            status = .created
            json = """
            {"data":{"type":"profiles","id":"new","attributes":{"profileContent":"!"}},
            "links":{"self":"https://example.test/profiles/new"}}
            """
        default:
            throw MockError.unexpectedRequest(operationID)
        }
        return (HTTPResponse(status: status, headerFields: [.contentType: "application/json"]), HTTPBody(Data(json.utf8)))
    }

    nonisolated func withEphemeralClient<T>(perform: (any HTTPClientProtocol) async throws -> T) async throws -> T {
        try await perform(self)
    }

    nonisolated func makeWebSocket(url: URL) async throws -> any WebSocketSession {
        throw MockError.unexpectedRequest("websocket")
    }

    enum MockError: Error { case unexpectedRequest(String) }
}
