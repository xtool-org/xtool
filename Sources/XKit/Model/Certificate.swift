//
//  Certificate.swift
//  Supercharge
//
//  Created by Kabir Oberai on 07/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import X509
import SwiftASN1

/// A certificate in DER format
public struct Certificate: Codable, Sendable {

    public enum Error: Swift.Error {
        case invalidCertificate
    }

    let raw: X509.Certificate

    public init(raw: X509.Certificate) throws {
        self.raw = raw
    }

    public init(data: Data) throws {
        try self.init(raw: .init(derEncoded: DER.parse(Array(data))))
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        try self.init(data: data)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(data())
    }

    private func subjectAttribute(_ attribute: ASN1ObjectIdentifier) throws -> String {
        let commonName = raw.subject.lazy.flatMap { $0 }.first { $0.type == attribute }
        guard let commonName, let parsed = String(commonName.value) else { throw Error.invalidCertificate }
        return parsed
    }

    public func developerIdentity() throws -> String {
        try subjectAttribute(.NameAttributes.commonName)
    }

    public func teamID() throws -> String {
        try subjectAttribute(.NameAttributes.organizationalUnitName)
    }

    public func serialNumber() -> String {
        // big endian, hex-encoded. Leading zero bytes are dropped, but not leading zero
        // nibbles: Apple formats serials like "03AB…", not "3AB…" (#305).
        raw.serialNumber.bytes
            .drop { $0 == 0 }
            .map { String(format: "%02hhX", $0) }
            .joined()
    }

    /// Whether `serialNumber` (hex-encoded, e.g. by the App Store Connect API)
    /// is this certificate's serial number.
    ///
    /// Compares numerically, so case and leading zeros don't matter.
    public func hasSerialNumber(_ serialNumber: String) -> Bool {
        func normalized(_ hex: String) -> Substring {
            hex.uppercased().drop { $0 == "0" }
        }
        return normalized(serialNumber) == normalized(self.serialNumber())
    }

    public func wasIssuedBefore(_ other: Certificate) -> Bool {
        raw.notValidBefore < other.raw.notValidBefore
    }

    public func data() throws -> Data {
        var serializer = DER.Serializer()
        try serializer.serialize(raw)
        return Data(serializer.serializedBytes)
    }

}
