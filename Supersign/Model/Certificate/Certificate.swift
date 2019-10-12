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
        data.withUnsafeBytes { bytes in
            let bound = bytes.bindMemory(to: Int8.self)
            return certificate_create_from_data(bound.baseAddress, bound.count)
        }
    }

    public init(data: Data) throws {
        guard let certificate = Self.certificate(from: data) else {
            throw Error.invalidCertificate
        }
        self.raw = certificate
    }

    public init(contentsOf url: URL) throws {
        guard let certificate = url.withUnsafeFileSystemRepresentation(certificate_create_from_path) else {
            throw Error.invalidCertificate
        }
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
        guard let serial = certificate_copy_serial_number(raw) else {
            throw Error.invalidCertificate
        }
        defer { free(serial) }
        return String(cString: serial)
    }

    public func data() throws -> Data {
        guard let data = Data(cFunc: { certificate_generate_data(raw, $0) })
            else { throw Error.invalidCertificate }
        return data
    }

}
