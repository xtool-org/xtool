//
//  DeveloperServicesListCertificatesRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesListCertificatesRequest: DeveloperServicesPlatformRequest {

    public struct Response: Decodable {
        public let certificates: [DeveloperServicesCertificate]
    }
    public typealias Value = [DeveloperServicesCertificate]

    public let platform: DeveloperServicesPlatform
    public let teamID: DeveloperServicesTeam.ID

    var subAction: String { return "listAllDevelopmentCerts" }
    var subParameters: [String: Any] {
        return ["teamId": teamID.rawValue]
    }

    public func parse(_ response: Response, completion: @escaping (Result<Value, Error>) -> Void) {
        completion(.success(response.certificates))
    }

    public init(platform: DeveloperServicesPlatform, teamID: DeveloperServicesTeam.ID) {
        self.platform = platform
        self.teamID = teamID
    }

}
