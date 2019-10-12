//
//  DeveloperServicesListTeamsRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesListTeamsRequest: DeveloperServicesRequest {

    public struct Response: Decodable {
        public let teams: [DeveloperServicesTeam]
    }
    public typealias Value = [DeveloperServicesTeam]

    public var action: String { return "listTeams" }
    public var parameters: [String: Any] { return [:] }

    public func parse(
        _ response: Response, completion: @escaping (Result<[DeveloperServicesTeam], Error>) -> Void
    ) {
        completion(.success(response.teams))
    }

    public init() {}

}
