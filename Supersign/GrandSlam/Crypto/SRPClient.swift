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
        data.withUnsafeBytes { buf in
            let bound = buf.bindMemory(to: Int8.self)
            srp_client_add_data(raw, bound.baseAddress!, bound.count)
        }
    }

    func decrypt(cbc: Data) -> Data? {
        cbc.withUnsafeBytes { buf in
            let bound = buf.bindMemory(to: Int8.self)
            var length = 0
            return srp_client_decrypt_cbc(raw, bound.baseAddress!, bound.count, &length)
                .map { Data(bytesNoCopy: $0, count: length, deallocator: .free) }
        }
    }

    // MARK: - SRP

    func startAuthenticationAndGetA() -> Data {
        var length = 0
        return Data(bytesNoCopy: srp_client_start_auth_and_get_a(raw, &length), count: length, deallocator: .free)
    }

    func processChallenge(
        withUsername username: String,
        password: String,
        salt: Data,
        iterations: Int,
        bData: Data,
        isS2K: Bool
    ) -> Data? {
        salt.withUnsafeBytes { saltBuf in
            bData.withUnsafeBytes { bDataBuf in
                let saltBound = saltBuf.bindMemory(to: Int8.self)
                let bDataBound = bDataBuf.bindMemory(to: Int8.self)
                var length = 0
                return srp_client_process_challenge(
                    raw,
                    username, password,
                    saltBound.baseAddress!, saltBound.count,
                    .init(iterations),
                    bDataBound.baseAddress!,
                    isS2K,
                    &length
                ).map { Data(bytesNoCopy: $0, count: length, deallocator: .free) }
            }
        }
    }

    func verify(m2: Data) -> Bool {
        m2.withUnsafeBytes { buf in
            let bound = buf.bindMemory(to: Int8.self)
            return srp_client_verify_session_m2(raw, bound.baseAddress!, bound.count)
        }
    }

    func verify(negProto: Data) -> Bool {
        negProto.withUnsafeBytes { buf in
            let bound = buf.bindMemory(to: Int8.self)
            return srp_client_verify_neg_proto(raw, bound.baseAddress!, bound.count)
        }
    }

}
