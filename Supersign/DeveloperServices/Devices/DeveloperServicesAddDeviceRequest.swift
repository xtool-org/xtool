//
//  DeveloperServicesAddDeviceRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesAddDeviceRequest: DeveloperServicesPlatformRequest {

    public struct Response: Decodable {
        let device: DeveloperServicesDevice
    }
    public typealias Value = DeveloperServicesDevice

    public let platform: DeveloperServicesPlatform
    public let teamID: DeveloperServicesTeam.ID
    public let udid: String
    public let name: String

    var subAction: String { return "addDevice" }
    var subParameters: [String: Any] {
        return [
            "teamId": teamID.rawValue,
            "deviceNumber": udid,
            "name": name
        ]
    }

    public func parse(_ response: Response, completion: @escaping (Result<Value, Error>) -> Void) {
        completion(.success(response.device))
    }

    public init(
        platform: DeveloperServicesPlatform,
        teamID: DeveloperServicesTeam.ID,
        udid: String,
        name: String
    ) {
        self.platform = platform
        self.teamID = teamID
        self.udid = udid
        self.name = name
    }

}
