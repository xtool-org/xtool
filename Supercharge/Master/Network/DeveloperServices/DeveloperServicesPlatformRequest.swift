//
//  DeveloperServicesPlatformRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

enum DeveloperServicesPlatform: String, Decodable {
    case iOS = "ios"
    case watchOS = "watchos"
    case tvOS = "tvos"

    fileprivate var os: String {
        switch self {
        case .iOS, .watchOS: return "ios"
        case .tvOS: return "tvos"
        }
    }

    fileprivate var subPlatform: String? {
        switch self {
        case .iOS, .watchOS: return nil
        case .tvOS: return "tvOS"
        }
    }
}

protocol DeveloperServicesPlatformRequest: DeveloperServicesRequest {
    var platform: DeveloperServicesPlatform { get }

    var subAction: String { get }
    var subParameters: [String: Any] { get }
}

extension DeveloperServicesPlatformRequest {

    var action: String { return "\(platform.os)/\(subAction)" }

    var parameters: [String: Any] {
        var parameters = subParameters
        parameters["DTDK_Platform"] = platform.rawValue
        parameters["subPlatform"] = platform.subPlatform
        return parameters
    }

}
