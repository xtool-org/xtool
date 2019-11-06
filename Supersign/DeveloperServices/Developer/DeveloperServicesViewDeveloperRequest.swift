//
//  DeveloperServicesViewDeveloperRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesViewDeveloperRequest: DeveloperServicesRequest {

    public struct Developer: Decodable {
        public let email: String

        public let firstName: String
        public let lastName: String

        public let dsFirstName: String
        public let dsLastName: String

        public let developerStatus: String
    }

    public struct Response: Decodable {
        let developer: Developer
    }
    public typealias Value = Developer

    public var action: String { return "viewDeveloper" }
    public var parameters: [String: Any] { return [:] }

    public func parse(_ response: Response, completion: @escaping (Result<Value, Error>) -> Void) {
        completion(.success(response.developer))
    }

    public init() {}

}
