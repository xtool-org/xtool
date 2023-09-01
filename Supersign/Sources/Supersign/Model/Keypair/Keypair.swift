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
import _CryptoExtras

public struct PrivateKey: Codable {
    // pem encoded
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}

public struct CSR {
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
        PrivateKey(data: Data(raw.pemRepresentation.utf8))
    }

    public func generateCSR() throws -> CSR {
        let request = try CertificateSigningRequest(
            version: .v1,
            subject: DistinguishedName {
                CountryName("US")
                CommonName("Supercharge")
            },
            privateKey: X509.Certificate.PrivateKey(raw),
            attributes: CertificateSigningRequest.Attributes(),
            signatureAlgorithm: .sha1WithRSAEncryption
        )
        return CSR(pemString: try request.serializeAsPEM().pemString)
    }

}
