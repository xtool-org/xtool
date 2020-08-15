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
            return Data {
                app_tokens_create_checksum(
                    skBuf.baseAddress, skBuf.count,
                    adsid,
                    immutablePtrArray, immutablePtrArray.count,
                    &$0
                )
            }
        }
    }

    static func decrypt(gcm: Data, withSK sk: Data) -> Data? {
        gcm.withUnsafeBytes { gcmBuf in
            sk.withUnsafeBytes { skBuf in
                // the data must have a header so it shouldn't be empty
                guard let gcmBase = gcmBuf.baseAddress,
                    // the session key must have a length equal to that required by
                    // the cipher. It should be non-empty.
                    let skBase = skBuf.baseAddress
                    else { return nil }
                return Data {
                    app_tokens_decrypt_gcm(gcmBase, gcmBuf.count, skBase, skBuf.count, &$0)
                }
            }
        }
    }

}
