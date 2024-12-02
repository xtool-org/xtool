//
//  GrandSlamRequest.swift
//  Supersign
//
//  Created by Kabir Oberai on 19/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

enum GrandSlamMethod {
    case get
    case post([String: Any])

    var name: String {
        switch self {
        case .get: return "GET"
        case .post: return "POST"
        }
    }
}

protocol GrandSlamDataDecoder {
    associatedtype Value
    static func decode(data: Data) throws -> Value
}

protocol GrandSlamRequest: Sendable {
    associatedtype Decoder: GrandSlamDataDecoder

    static var endpoint: GrandSlamEndpoint { get }

    func configure(request: inout HTTPRequest, deviceInfo: DeviceInfo, anisetteData: AnisetteData)
    func method(deviceInfo: DeviceInfo, anisetteData: AnisetteData) -> GrandSlamMethod
}
