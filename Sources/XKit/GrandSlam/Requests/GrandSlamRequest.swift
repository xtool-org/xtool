//
//  GrandSlamRequest.swift
//  XKit
//
//  Created by Kabir Oberai on 19/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import HTTPTypes

enum GrandSlamRequestContent {
    enum ContentType {
        case xml
        case json
    }

    case get
    case data([String: Any], method: HTTPRequest.Method, type: ContentType = .xml)

    static func post(_ body: [String: Any], type: ContentType = .xml) -> Self {
        .data(body, method: .post, type: type)
    }

    static func put(_ body: [String: Any], type: ContentType = .xml) -> Self {
        .data(body, method: .put, type: type)
    }

    var httpMethod: HTTPRequest.Method {
        switch self {
        case .get: return .get
        case .data(_, let method, _): return method
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

    func configure(request: inout HTTPRequest, anisetteData: AnisetteData)
    func content(anisetteData: AnisetteData) -> GrandSlamRequestContent
}
