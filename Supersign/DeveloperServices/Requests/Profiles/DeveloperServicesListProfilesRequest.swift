//
//  DeveloperServicesListProfilesRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesListProfilesRequest: DeveloperServicesPlatformRequest {

    public struct Response: Decodable {
        public let provisioningProfiles: [DeveloperServicesProfile]
    }
    public typealias Value = [DeveloperServicesProfile]

    public let platform: DeveloperServicesPlatform
    public let teamID: DeveloperServicesTeam.ID

    var subAction: String { return "listProvisioningProfiles" }
    var subParameters: [String: Any] {
        return ["teamId": teamID.rawValue]
    }

    public func parse(_ response: Response, completion: @escaping (Result<Value, Error>) -> Void) {
        completion(.success(response.provisioningProfiles))
    }

    public init(platform: DeveloperServicesPlatform, teamID: DeveloperServicesTeam.ID) {
        self.platform = platform
        self.teamID = teamID
    }

}
