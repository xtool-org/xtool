//
//  GrandSlamAuthEndpoint.swift
//  XKit
//
//  Created by Kabir Oberai on 20/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

enum GrandSlamAuthMode: String, Decodable {
    case secondaryAuth
    case trustedDeviceSecondaryAuth
}
