//
//  DeveloperServicesRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

protocol DeveloperServicesRequest {

    associatedtype Response: Decodable
    associatedtype Value

    var action: String { get }
    var parameters: [String: Any] { get }

    func configure(urlRequest: inout URLRequest)

    func parse(_ response: Response, completion: @escaping (Result<Value, Error>) -> Void)
}

extension DeveloperServicesRequest {
    func configure(urlRequest: inout URLRequest) {}
}

extension DeveloperServicesRequest where Response == Value {
    func parse(_ response: Response, completion: @escaping (Result<Value, Error>) -> Void) {
        completion(.success(response))
    }
}
