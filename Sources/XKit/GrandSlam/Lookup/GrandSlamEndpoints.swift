//
//  GrandSlamEndpoints.swift
//  XKit
//
//  Created by Kabir Oberai on 19/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

struct GrandSlamEndpoints: Decodable {
    let gsService: String
    let secondaryAuth: String
    let trustedDeviceSecondaryAuth: String
    let validateCode: String
    let midStartProvisioning: String
    let midFinishProvisioning: String
}

enum GrandSlamEndpoint: Sendable {
    case lookup(KeyPath<GrandSlamEndpoints, String> & Sendable)
    case url(URL)
}
