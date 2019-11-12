//
//  DeveloperServicesPlatformRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public enum DeveloperServicesPlatform: Decodable, CaseIterable {
    case unknown
    case iOS
    case watchOS
    case tvOS

    var rawValue: String {
        switch self {
        case .iOS: return "ios"
        case .watchOS: return "watchos"
        case .tvOS: return "tvos"
        case .unknown: return ""
        }
    }

    var os: String {
        switch self {
        case .iOS, .watchOS: return "ios"
        case .tvOS: return "tvos"
        case .unknown: return ""
        }
    }

    var subPlatform: String? {
        switch self {
        case .iOS, .watchOS: return nil
        case .tvOS: return "tvOS"
        case .unknown: return ""
        }
    }

    public static let current: DeveloperServicesPlatform = {
        #if os(tvOS)
        return .tvOS
        #elseif os(watchOS)
        return .watchOS
        #else
        return .iOS
        #endif
    }()

    public init(from decoder: Decoder) throws {
        let rawValue = try String(from: decoder)
        self = Self.allCases.first { $0.rawValue == rawValue } ?? .unknown
    }
}

protocol DeveloperServicesPlatformRequest: DeveloperServicesRequest {
    var platform: DeveloperServicesPlatform { get }

    var subAction: String { get }
    var subParameters: [String: Any] { get }
}

extension DeveloperServicesPlatformRequest {

    public var action: String { return "\(platform.os)/\(subAction)" }

    public var parameters: [String: Any] {
        var parameters = subParameters
        parameters["DTDK_Platform"] = platform.rawValue
        parameters["subPlatform"] = platform.subPlatform
        return parameters
    }

}
