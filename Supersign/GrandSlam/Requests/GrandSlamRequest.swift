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

//enum GrandSlamDecodeStrategy<T: Decodable> {
//    case always(T)
//    case plist
//
//    func decode(data: Data) throws -> T {
//        switch self {
//        case .always(let value): return value
//        case .plist: return try PropertyListDecoder().decode(T.self, from: data)
//        }
//    }
//}

protocol GrandSlamDataDecoder {
    associatedtype Value
    static func decode(data: Data) throws -> Value
}

protocol GrandSlamRequest {
    associatedtype Decoder: GrandSlamDataDecoder

    static var endpoint: GrandSlamEndpoint { get }

    func configure(request: inout URLRequest, deviceInfo: DeviceInfo, anisetteData: AnisetteData)
    func method(deviceInfo: DeviceInfo, anisetteData: AnisetteData) -> GrandSlamMethod
}

extension GrandSlamRequest {
//    func configure(request: inout URLRequest, deviceInfo: DeviceInfo, anisetteData: AnisetteData) {}
}
