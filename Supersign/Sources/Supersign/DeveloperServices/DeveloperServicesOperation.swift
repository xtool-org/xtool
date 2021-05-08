//
//  DeveloperServicesOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public protocol DeveloperServicesOperation {
    associatedtype Response

    var context: SigningContext { get }

    func perform(completion: @escaping (Result<Response, Error>) -> Void)
}
