//
//  DeveloperServicesPlatformRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public enum DeveloperServicesPlatform: Decodable, Hashable, Sendable {
    private static let known: ([String: DeveloperServicesPlatform], [DeveloperServicesPlatform: String]) = {
        var first: [String: DeveloperServicesPlatform] = [:]
        var second: [DeveloperServicesPlatform: String] = [:]
        func add(_ platform: DeveloperServicesPlatform, _ name: String? = nil) {
            let name = name ?? "\(platform)"
            first[name] = platform
            second[platform] = name
        }

        add(.macOS, "mac")
        add(.iOS, "ios")
        add(.watchOS, "watchOS")
        add(.tvOS, "tvOS")
        add(.safari)

        return (first, second)
    }()

    case macOS
    case iOS
    case watchOS
    case tvOS
    case safari
    case unknown(String)

    var rawValue: String {
        switch self {
        case .unknown(let val):
            return val
        default:
            return Self.known.1[self] ?? "\(self)"
        }
    }

    var os: String {
        switch self {
        case .iOS, .watchOS: return "ios"
        case .tvOS: return "tvos"
        default: return ""
        }
    }

    var subPlatform: String? {
        switch self {
        case .iOS, .watchOS: return nil
        case .tvOS: return "tvOS"
        default: return ""
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
        self = Self.known.0[rawValue] ?? .unknown(rawValue)
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
