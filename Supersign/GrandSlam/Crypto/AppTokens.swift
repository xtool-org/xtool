//
//  AppTokens.swift
//  Supersign
//
//  Created by Kabir Oberai on 11/04/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import Foundation

enum AppTokens {

    static func checksum(withSK sk: Data, adsid: String, apps: [String]) -> Data {
        sk.withUnsafeBytes { skBuf in
            let ptrArray = apps.map { strdup($0)! }
            defer { ptrArray.forEach { free($0) } }
            let immutablePtrArray = ptrArray.map { UnsafePointer($0) }
            return immutablePtrArray.withUnsafeBufferPointer { ptrBuf in
                var length = 0
                let bytes = app_tokens_create_checksum(
                    skBuf.baseAddress!, skBuf.count, adsid, ptrBuf.baseAddress!, ptrBuf.count, &length
                )
                return Data(bytesNoCopy: bytes, count: length, deallocator: .free)
            }
        }
    }

    static func decrypt(gcm: Data, withSK sk: Data) -> Data? {
        gcm.withUnsafeBytes { gcmBuf in
            sk.withUnsafeBytes { skBuf in
                var length = 0
                return app_tokens_decrypt_gcm(
                    gcmBuf.baseAddress!, gcmBuf.count,
                    skBuf.baseAddress!, skBuf.count,
                    &length
                ).map { Data(bytesNoCopy: $0, count: length, deallocator: .free) }
            }
        }
    }

}
