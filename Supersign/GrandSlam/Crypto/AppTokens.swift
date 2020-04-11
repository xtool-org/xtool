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
        sk.withUnsafeBytes { buf in
            let bound = buf.bindMemory(to: Int8.self)
            let ptrArray = apps.map { strdup($0)! }
            defer { ptrArray.forEach { free($0) } }
            let immutablePtrArray = ptrArray.map { UnsafePointer($0) }
            return immutablePtrArray.withUnsafeBufferPointer { buf in
                var length = 0
                let bytes = app_tokens_create_checksum(
                    bound.baseAddress!, bound.count, adsid, buf.baseAddress!, buf.count, &length
                )
                return Data(bytesNoCopy: bytes, count: length, deallocator: .free)
            }
        }
    }

    static func decrypt(gcm: Data, sk: Data) -> Data? {
        gcm.withUnsafeBytes { gcmBuf in
            sk.withUnsafeBytes { skBuf in
                let gcmBound = gcmBuf.bindMemory(to: Int8.self)
                let skBound = skBuf.bindMemory(to: Int8.self)
                var length = 0
                return app_tokens_decrypt_gcm(
                    gcmBound.baseAddress!, gcmBound.count,
                    skBound.baseAddress!, skBound.count,
                    &length
                ).map { Data(bytesNoCopy: $0, count: length, deallocator: .free) }
            }
        }
    }

}
