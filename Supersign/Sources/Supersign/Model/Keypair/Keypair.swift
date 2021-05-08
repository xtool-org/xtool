//
//  Keypair.swift
//  Supercharge
//
//  Created by Kabir Oberai on 07/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import CSupersign

public struct PrivateKey: Codable {
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

public final class Keypair {

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

    public func privateKey() throws -> PrivateKey {
        try PrivateKey(data: Data { keypair_copy_private_key(raw, &$0) }.orThrow(Error.invalidKeypair))
    }

    public func generateCSR() throws -> CSR {
        try CSR(data: Data { keypair_generate_csr(raw, &$0) }.orThrow(Error.invalidKeypair))
    }

}
