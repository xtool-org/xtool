//
//  Certificate.swift
//  Supercharge
//
//  Created by Kabir Oberai on 07/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public class Certificate: Decodable {

    public enum Error: Swift.Error {
        case invalidCertificate
    }

    let raw: certificate_t

    private static func certificate(from data: Data) -> certificate_t? {
        data.withUnsafeBytes {
            guard let base = $0.baseAddress else { return nil }
            return certificate_create_from_data(base, $0.count)
        }
    }

    public init(data: Data) throws {
        guard let certificate = Self.certificate(from: data) else {
            throw Error.invalidCertificate
        }
        self.raw = certificate
    }

    public init(contentsOf url: URL) throws {
        guard let certificate = url.withUnsafeFileSystemRepresentation({ $0.flatMap(certificate_create_from_path) })
            else { throw Error.invalidCertificate }
        self.raw = certificate
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        guard let certificate = Self.certificate(from: data) else {
            throw Error.invalidCertificate
        }
        self.raw = certificate
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
