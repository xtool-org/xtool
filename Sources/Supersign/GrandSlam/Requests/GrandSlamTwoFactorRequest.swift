//
//  GrandSlamTwoFactorRequest.swift
//  Supersign
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

protocol GrandSlamTwoFactorRequest: GrandSlamRequest {
    var loginData: GrandSlamLoginData { get }
    var extraHeaders: [String: String] { get }
}

extension GrandSlamTwoFactorRequest {

    var extraHeaders: [String: String] { [:] }

    func configure(request: inout HTTPRequest, deviceInfo: DeviceInfo, anisetteData: AnisetteData) {
        request.headers["Accept"] = "application/x-buddyml"
        request.headers["Content-Type"] = "application/x-plist"
        request.headers["X-Apple-App-Info"] = "com.apple.gs.xcode.auth"
        request.headers[DeviceInfo.xcodeVersionKey] = DeviceInfo.xcodeVersion
        request.headers["X-Apple-Identity-Token"] = loginData.identityToken
        anisetteData.dictionary.forEach { request.headers[$0] = $1 }
        extraHeaders.forEach { request.headers[$0] = $1 }
    }

    func method(deviceInfo: DeviceInfo, anisetteData: AnisetteData) -> GrandSlamMethod {
        .get
    }

}
