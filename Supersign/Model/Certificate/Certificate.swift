//
//  Certificate.swift
//  Supercharge
//
//  Created by Kabir Oberai on 07/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

/// A certificate in DER format
public final class Certificate: Codable {

    public enum Error: Swift.Error {
        case invalidCertificate
    }

    let raw: certificate_t

    public init(data: Data) throws {
        self.raw = try data.withUnsafeBytes { buf -> certificate_t in
            guard let base = buf.baseAddress,
                  let cert = certificate_create_from_data(base, buf.count)
            else { throw Error.invalidCertificate }
            return cert
        }
    }

    public init(contentsOf url: URL) throws {
        guard let certificate = url.withUnsafeFileSystemRepresentation({ $0.flatMap(certificate_create_from_path) })
            else { throw Error.invalidCertificate }
        self.raw = certificate
    }

    public required convenience init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        try self.init(data: data)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(data())
    }

    deinit {
        certificate_free(raw)
    }

    public func developerIdentity() throws -> String {
        guard let identity = certificate_get_developer_identity(raw) else {
            throw Error.invalidCertificate
        }
        return String(cString: identity)
    }

    public func serialNumber() throws -> String {
        guard let serial = certificate_copy_serial_number(raw),
            let string = String(bytesNoCopy: serial, length: strlen(serial), encoding: .utf8, freeWhenDone: true)
            else { throw Error.invalidCertificate }
        return string
    }

    public func data() throws -> Data {
        try Data { certificate_generate_data(raw, &$0) }
            .orThrow(Error.invalidCertificate)
    }

}
