//
//  SRPClient.swift
//  XKit
//
//  Created by Kabir Oberai on 11/04/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import Foundation
import Crypto
import _CryptoExtras
import BigInt

struct SRPClient {

    enum Errors: Error {
        case internalError
        case notProcessed
    }

    // 2048-bit SRP 6a group
    private static let N = BigUInt(
        """
        AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC319294\
        3DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310D\
        CD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FB\
        D5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF74\
        7359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A\
        436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D\
        5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E73\
        03CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6\
        94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F\
        9E4AFF73
        """,
        radix: 16
    )!
    private static let g: BigUInt = 2

    private let clientPrivateKey: BigUInt
    private let clientPublicKey: BigUInt

    init() {
        clientPrivateKey = SymmetricKey(size: .init(bitCount: 256))
            .withUnsafeBytes { BigUInt($0) }
        clientPublicKey = Self.g.power(clientPrivateKey, modulus: Self.N)
    }

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
        clientPublicKey.serialize()
    }

    mutating func processChallenge(
        withUsername username: String,
        password: String,
        salt: Data,
        iterations: Int,
        isLegacyProtocol: Bool,
        serverPublicKey rawB: Data
    ) throws -> Data {
        let N = Self.N
        let B = BigUInt(rawB)
        guard !(B % N).isZero else { throw Errors.internalError }

        let g = Self.g
        let a = clientPrivateKey
        let A = clientPublicKey

        let hashedPassword = Data(SHA256.hash(data: Data(password.utf8)))
        let pbkdfInput = if isLegacyProtocol {
            Data(hashedPassword.map { String(format: "%02hhx", $0) }.joined().utf8)
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
            .withUnsafeBytes { BigUInt($0) }

        let u = calcXY(x: A, y: B)
        let k = calcXY(x: N, y: g)
        let rawK = BigUInt((BigInt(B) - BigInt((g.power(x, modulus: N) * k) % N)).modulus(BigInt(N)))
            .power(a + (u * x), modulus: N)

        let K = Data(SHA256.hash(data: rawK.serialize()))
        clientKey = SymmetricKey(data: K)

        let AData = A.serialize()
        let gHash = SHA256.hash(data: g.serialize().padded(to: SHA256.byteCount * 8))
        let NHash = SHA256.hash(data: N.serialize())
        let xorHash = zip(gHash, NHash).map { $0 ^ $1 }
        let HI = SHA256.hash(data: Data(username.utf8))
        let M = Data(SHA256.hash(data: xorHash + Data(HI) + salt + AData + rawB + K))
        hamk = SymmetricKey(data: SHA256.hash(data: AData + M + K))

        return M
    }

    private func calcXY(x: BigUInt, y: BigUInt) -> BigUInt {
        let expectedCount = (Self.N.bitWidth + 7) / 8
        let padX = x.serialize().padded(to: expectedCount)
        let padY = y.serialize().padded(to: expectedCount)
        let hash = SHA256.hash(data: padX + padY)
        return hash.withUnsafeBytes { BigUInt($0) }
    }

}

extension Data {
    fileprivate func padded(to count: Int) -> Data {
        if self.count < count {
            Array(repeating: 0, count: count - self.count) + self
        } else {
            self
        }
    }
}
