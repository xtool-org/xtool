//
//  SRPClient.swift
//  Supersign
//
//  Created by Kabir Oberai on 11/04/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import Foundation
import CSupersign
import Crypto

struct SRPClient: ~Copyable {

    enum Errors: Error {
        case notProcessed
    }

    let raw = srp_client_create()
    deinit { srp_client_free(raw) }

    private var digest = SHA256()
    private var hamk: SymmetricKey?
    private var clientKey: SymmetricKey?

    // MARK: - Encryption & decryption

    mutating func add(string: String) {
        var copy = string
        copy.withUTF8 { digest.update(bufferPointer: UnsafeRawBufferPointer($0)) }
    }

    mutating func add(data: Data) {
        withUnsafeBytes(of: UInt32(data.count)) {
            digest.update(bufferPointer: $0)
        }
        digest.update(data: data)
    }

    func decrypt(cbc: Data) throws -> Data {
        let key = try sessionKey(name: "extra data key:")
        let iv = try sessionKey(name: "extra data iv:").withUnsafeBytes {
            try AES._CBC.IV(ivBytes: $0.prefix(16))
        }
        return try AES._CBC.decrypt(cbc, using: key, iv: iv)
    }

    private func sessionKey(name: String) throws -> SymmetricKey {
        guard let clientKey else { throw Errors.notProcessed }
        return SymmetricKey(data: HMAC<SHA256>.authenticationCode(for: Data(name.utf8), using: clientKey))
    }

    func verify(negProto: Data) -> Bool {
        let hash = Data(digest.finalize())
        guard let key = try? sessionKey(name: "HMAC key:") else { return false }
        let mac = SymmetricKey(data: HMAC<SHA256>.authenticationCode(for: hash, using: key))
        return SymmetricKey(data: negProto) == mac
    }

    func verify(hamk: Data) -> Bool {
        SymmetricKey(data: hamk) == self.hamk
    }

    // MARK: - SRP

    func publicKey() -> Data {
        Data { srp_client_copy_public_key(raw, &$0) }
    }

    mutating func processChallenge(
        withUsername username: String,
        passkey: Data,
        salt: Data,
        serverPublicKey key: Data
    ) -> Data? {
        var outResponse: UnsafeMutableRawPointer?
        var outHAMK: UnsafeMutableRawPointer?
        var outClientKey: UnsafeMutableRawPointer?
        let outLen = passkey.withUnsafeBytes { passkeyBuf in
            salt.withUnsafeBytes { saltBuf in
                key.withUnsafeBytes { keyBuf in
                    srp_client_process_challenge(
                        raw,
                        username,
                        passkeyBuf.baseAddress!, passkeyBuf.count,
                        saltBuf.baseAddress, saltBuf.count,
                        keyBuf.baseAddress, keyBuf.count,
                        &outHAMK,
                        &outClientKey,
                        &outResponse
                    )
                }
            }
        }
        guard outLen > 0, let outResponse, let outHAMK, let outClientKey else { return nil }
        hamk = SymmetricKey(data: UnsafeRawBufferPointer(start: outHAMK, count: outLen))
        free(outHAMK)
        clientKey = SymmetricKey(data: UnsafeRawBufferPointer(start: outClientKey, count: outLen))
        free(outClientKey)
        return Data(bytesNoCopy: outResponse, count: outLen, deallocator: .free)
    }

}
