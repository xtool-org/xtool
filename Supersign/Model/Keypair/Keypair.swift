//
//  Keypair.swift
//  Supercharge
//
//  Created by Kabir Oberai on 07/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct PrivateKey {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }

    public init(contentsOf url: URL) throws {
        self.data = try Data(contentsOf: url)
    }
}

public struct CSR {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }

    public init(contentsOf url: URL) throws {
        self.data = try Data(contentsOf: url)
    }
}

public class Keypair {

    public enum Error: Swift.Error {
        case couldNotCreate
        case invalidKeypair
    }

    let raw: keypair_t

    public init() throws {
        guard let keypair = keypair_create() else {
            throw Error.couldNotCreate
        }
        self.raw = keypair
    }

    deinit {
        keypair_free(raw)
    }

    private func callKeypairDataFunc(
        fn: (keypair_t?, UnsafeMutablePointer<Int>?) -> UnsafeMutablePointer<Int8>?
    ) throws -> Data {
        var len = 0
        guard let bytes = fn(raw, &len) else {
            throw Error.invalidKeypair
        }
        defer { free(bytes) }
        return Data(bytes: UnsafeRawPointer(bytes), count: len)
    }

    public func privateKey() throws -> PrivateKey {
        guard let data = Data(cFunc: { keypair_copy_private_key(raw, $0) })
            else { throw Error.invalidKeypair }
        return PrivateKey(data: data)
    }

    public func generateCSR() throws -> CSR {
        guard let data = Data(cFunc: { keypair_generate_csr(raw, $0) })
            else { throw Error.invalidKeypair }
        return CSR(data: data)
    }

}
