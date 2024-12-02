//
//  Entitlement.swift
//  Supercharge
//
//  Created by Kabir Oberai on 29/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import ProtoCodable

public protocol Entitlement: ProtoCodable, Sendable {
    static var identifier: String { get }
    static var isFree: Bool { get }
    /// whether this entitlement should be included in developer services API requests
    static var canList: Bool { get }
}

public extension Entitlement {
    static var canList: Bool { return true }
}
