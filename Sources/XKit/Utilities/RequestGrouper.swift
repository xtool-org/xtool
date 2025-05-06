//
//  RequestGrouper.swift
//  XKit
//
//  Created by Kabir Oberai on 14/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct ErrorList<E: Error>: LocalizedError {

    public let errors: [E]
    public init(_ errors: [E]) {
        self.errors = errors
    }

    public var errorDescription: String? {
        errors.map { $0.localizedDescription }.localizedJoined()
    }

}
