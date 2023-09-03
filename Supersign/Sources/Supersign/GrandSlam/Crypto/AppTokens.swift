//
//  AppTokens.swift
//  Supersign
//
//  Created by Kabir Oberai on 11/04/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import Foundation
import Crypto

enum AppTokens {

    static func checksum(withSK sk: Data, adsid: String, apps: [String]) -> Data {
        var hmac = HMAC<SHA256>(key: SymmetricKey(data: sk))
        hmac.update(data: Data("apptokens".utf8))
        hmac.update(data: Data(adsid.utf8))
        for app in apps {
            hmac.update(data: Data(app.utf8))
        }
        return Data(hmac.finalize())
    }

    // AppleIDAuthSupport`_AppleIDAuthSupportCreateDecryptedData
    static func decrypt(gcm: Data, withSK sk: Data) throws -> Data {
        let aad = gcm[..<3] // should be "XYZ"
        let iv = gcm[3..<19]
        let payload = gcm[19..<(gcm.count - 16)]
        let tag = gcm[(gcm.count - 16)...]

        return try AES.GCM.open(
            AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: iv),
                ciphertext: payload,
                tag: tag
            ),
            using: SymmetricKey(data: sk),
            authenticating: aad
        )
    }

}
