//
//  DeveloperServicesListDevicesRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesListDevicesRequest: DeveloperServicesPlatformRequest {

    public struct Response: Decodable {
        public let devices: [DeveloperServicesDevice]
    }
    public typealias Value = [DeveloperServicesDevice]

    public let platform: DeveloperServicesPlatform
    public let teamID: DeveloperServicesTeam.ID

    var subAction: String { return "listDevices" }
    var subParameters: [String: Any] {
        return [
            "teamId": teamID.rawValue,
            "pageSize": "500",
            "includeRemovedDevices": "false"
        ]
    }

    public func parse(_ response: Response, completion: @escaping (Result<Value, Error>) -> Void) {
        completion(.success(response.devices))
    }

    public init(platform: DeveloperServicesPlatform, teamID: DeveloperServicesTeam.ID) {
        self.platform = platform
        self.teamID = teamID
    }

}
