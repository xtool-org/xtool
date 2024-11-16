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
import _CryptoExtras

struct SRPClient: ~Copyable {

    enum Errors: Error {
        case internalError
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
        password: String,
        salt: Data,
        iterations: Int,
        isLegacyProtocol: Bool,
        serverPublicKey B: Data
    ) throws -> Data {
        let hashedPassword = Data(SHA256.hash(data: Data(password.utf8)))
        let pbkdfInput = if isLegacyProtocol {
            Data(hashedPassword.map { String(format: "%02hhx", $0) }.joined(separator: "").utf8)
        } else {
            hashedPassword
        }
        let passkey = try KDF.Insecure.PBKDF2.deriveKey(
            from: pbkdfInput,
            salt: salt,
            using: .sha256,
            outputByteCount: SHA256.byteCount,
            unsafeUncheckedRounds: iterations
        ).withUnsafeBytes { Data($0) }

        let x = SHA256.hash(data: salt + SHA256.hash(data: ":".utf8 + passkey))

        var outClientKey: UnsafeMutableRawPointer?
        var outClientKeyLen = 0
        var outG: UnsafeMutableRawPointer?
        var outGLen = 0
        var outN: UnsafeMutableRawPointer?
        var outNLen = 0
        let success = x.withUnsafeBytes { xBuf in
            salt.withUnsafeBytes { saltBuf in
                B.withUnsafeBytes { keyBuf in
                    srp_client_process_challenge(
                        raw,
                        xBuf.baseAddress!, xBuf.count,
                        keyBuf.baseAddress, keyBuf.count,
                        &outClientKey, &outClientKeyLen,
                        &outG, &outGLen,
                        &outN, &outNLen
                    )
                }
            }
        }
        guard success else { throw Errors.internalError }

        let rawK = Data(bytesNoCopy: outClientKey!, count: outClientKeyLen, deallocator: .free)
        let K = Data(SHA256.hash(data: rawK))
        let g = Data(bytesNoCopy: outG!, count: outGLen, deallocator: .free)
        let N = Data(bytesNoCopy: outN!, count: outNLen, deallocator: .free)
        clientKey = SymmetricKey(data: K)

        let gHash = SHA256.hash(data: Array(repeating: 0, count: SHA256.byteCount * 8 - g.count) + g)
        let NHash = SHA256.hash(data: N)
        let xorHash = zip(gHash, NHash).map { $0 ^ $1 }
        let HI = SHA256.hash(data: Data(username.utf8))
        let A = publicKey()

        let M = Data(SHA256.hash(data: xorHash + Data(HI) + salt + A + B + K))
        hamk = SymmetricKey(data: SHA256.hash(data: A + M + K))
        return M
    }

}
