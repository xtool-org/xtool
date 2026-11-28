//
//  Keypair.swift
//  Supercharge
//
//  Created by Kabir Oberai on 07/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import Crypto
import X509
import CryptoExtras

public struct PrivateKey: Codable, Sendable {
    let raw: X509.Certificate.PrivateKey

    public init(raw: X509.Certificate.PrivateKey) {
        self.raw = raw
    }

    public init(pemEncoded pem: String) throws {
        try self.init(raw: .init(pemEncoded: pem))
    }

    private enum CodingKeys: String, CodingKey {
        case data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let data = try container.decode(Data.self, forKey: .data)
        try self.init(pemEncoded: String(decoding: data, as: UTF8.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pemData(), forKey: .data)
    }

    public func pemData() throws -> Data {
        Data((try raw.serializeAsPEM().pemString + "\n").utf8)
    }
}

public struct CSR: Sendable {
    public let pemString: String

    public init(pemString: String) {
        self.pemString = pemString
    }
}

public struct Keypair {

    public enum Error: Swift.Error {
        case couldNotCreate
        case invalidKeypair
    }

    // Apple developer certs seem to require RSA2048
    let raw: _RSA.Signing.PrivateKey

    public init() throws {
        self.raw = try _RSA.Signing.PrivateKey(keySize: .bits2048)
    }

    public func privateKey() throws -> PrivateKey {
        PrivateKey(raw: .init(raw))
    }

    public func generateCSR() throws -> CSR {
        let request = try CertificateSigningRequest(
            version: .v1,
            subject: DistinguishedName {
                CountryName("US")
                CommonName("xtool")
            },
            privateKey: X509.Certificate.PrivateKey(raw),
            attributes: CertificateSigningRequest.Attributes(),
            signatureAlgorithm: .sha1WithRSAEncryption
        )
        return CSR(pemString: try request.serializeAsPEM().pemString)
    }

}
