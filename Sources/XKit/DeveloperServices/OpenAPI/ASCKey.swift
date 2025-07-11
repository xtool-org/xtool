import Foundation
import Crypto

public struct ASCKey: Sendable {
    public var id: String
    public var issuerID: String
    public var pem: String

    public init(id: String, issuerID: String, pem: String) {
        self.id = id
        self.issuerID = issuerID
        self.pem = pem
    }
}

actor ASCJWTGenerator {
    // the duration for which we generate JWTs.
    // ASC allows a maximum of 20 minutes.
    //
    // Apple sometimes rounds up, causing the expiry to go over 20 seconds.
    // This leads to an invalid token.
    private static let ttl: TimeInterval = 60 * 19

    // the minimum remaining ttl for us to consider reusing a previous key.
    // that is, we reuse the last JWT if it has at least [threshold] seconds
    // left before it expires.
    private static let tolerance: TimeInterval = 60

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private var lastJWT: (jwt: String, renewAt: Date)?

    private var parsedKey: P256.Signing.PrivateKey?

    nonisolated let key: ASCKey
    init(key: ASCKey) {
        self.key = key
    }

    private struct Header: Encodable {
        let alg = "ES256"
        let typ = "JWT"
        let kid: String
    }

    private struct Payload: Encodable {
        let aud = "appstoreconnect-v1"
        let iss: String
        let iat: Date
        let exp: Date
    }

    private func encode(_ value: some Encodable) throws -> String {
        try ASCJWTGenerator.encoder.encode(value).base64URLEncodedString()
    }

    private func getKey() throws -> P256.Signing.PrivateKey {
        if let parsedKey { return parsedKey }

        let key = try P256.Signing.PrivateKey(pemRepresentation: key.pem)
        self.parsedKey = key

        return key
    }

    func generate() throws -> String {
        if let lastJWT, lastJWT.renewAt > Date() {
            return lastJWT.jwt
        }

        let encodedHeader = try encode(Header(kid: key.id))

        let issuedAt = Date()
        let expiry = issuedAt + ASCJWTGenerator.ttl
        let renewAt = expiry - ASCJWTGenerator.tolerance
        let encodedPayload = try encode(Payload(iss: key.issuerID, iat: issuedAt, exp: expiry))

        let body = "\(encodedHeader).\(encodedPayload)"
        let signature = try getKey()
            .signature(for: Data(body.utf8))
            .rawRepresentation
            .base64URLEncodedString()

        let jwt = "\(body).\(signature)"
        lastJWT = (jwt, renewAt)
        return jwt
    }
}

extension Data {
    fileprivate func base64URLEncodedString() -> String {
        self
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
