//
//  DeveloperServicesRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct EmptyResponse: Decodable {}

public protocol DeveloperServicesRequest {

    associatedtype Response: Decodable
    associatedtype Value

    var apiVersion: DeveloperServicesAPIVersion { get }

    var methodOverride: String? { get }
    var action: String { get }
    var parameters: [String: Any] { get }

    func configure(urlRequest: inout HTTPRequest)

    func parse(_ response: Response, completion: @escaping (Result<Value, Error>) -> Void)
}

public extension DeveloperServicesRequest {
    var apiVersion: DeveloperServicesAPIVersion { DeveloperServicesAPIVersionOld() }
    var methodOverride: String? { nil }
    func configure(urlRequest: inout HTTPRequest) {}
}

public extension DeveloperServicesRequest where Response == Value {
    func parse(_ response: Response, completion: @escaping (Result<Value, Error>) -> Void) {
        completion(.success(response))
    }
}
