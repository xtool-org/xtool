//
//  SRPClient.swift
//  Supersign
//
//  Created by Kabir Oberai on 11/04/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import Foundation

class SRPClient {

    let raw = srp_client_create()
    deinit { srp_client_free(raw) }

    // MARK: - Encryption & decryption

    func add(string: String) {
        srp_client_add_string(raw, string)
    }

    func add(data: Data) {
        data.withUnsafeBytes { srp_client_add_data(raw, $0.baseAddress, $0.count) }
    }

    func decrypt(cbc: Data) -> Data? {
        cbc.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return nil }
            return Data { srp_client_decrypt_cbc(raw, base, buf.count, &$0) }
        }
    }

    // MARK: - SRP

    func publicKey() -> Data {
        Data { srp_client_copy_public_key(raw, &$0) }
    }

    func processChallenge(
        withUsername username: String,
        password: String,
        salt: Data,
        iterations: Int,
        serverPublicKey key: Data,
        isS2K: Bool
    ) -> Data? {
        salt.withUnsafeBytes { saltBuf in
            key.withUnsafeBytes { keyBuf in
                Data {
                    srp_client_process_challenge(
                        raw,
                        username, password,
                        saltBuf.baseAddress, saltBuf.count,
                        .init(iterations),
                        keyBuf.baseAddress, keyBuf.count,
                        isS2K,
                        &$0
                    )
                }
            }
        }
    }

    func verify(hamk: Data) -> Bool {
        hamk.withUnsafeBytes {
            // a hash has to be non-zero sized, so a nil baseAddress is invalid
            guard let base = $0.baseAddress else { return false }
            return srp_client_verify_session_HAMK(raw, base, $0.count)
        }
    }

    func verify(negProto: Data) -> Bool {
        negProto.withUnsafeBytes {
            guard let base = $0.baseAddress else { return false }
            return srp_client_verify_neg_proto(raw, base, $0.count)
        }
    }

}
