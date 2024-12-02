//
//  DeveloperServicesOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public protocol DeveloperServicesOperation: Sendable {
    associatedtype Response

    var context: SigningContext { get }

    func perform() async throws -> Response
}
