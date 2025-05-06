//
//  EntitlementContainer.swift
//  Supercharge
//
//  Created by Kabir Oberai on 19/09/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import ProtoCodable
import Superutils

public struct EntitlementContainer: ProtoCodableContainer, Sendable {
    public var value: Entitlement
    public init(value: Entitlement) { self.value = value }
}

// allows access to a parsable entitlements list while not losing unparsed entitlements when it's modified
public struct Entitlements: Sendable {

    private static let decoder = PropertyListDecoder()
    private static let encoder = PropertyListEncoder()

    private var dict: [String: AnyEncodable]

    public init(entitlements: [Entitlement]) throws {
        dict = [:]
        try setEntitlements(entitlements)
    }

    public func entitlements() throws -> [Entitlement] {
        try Self.decoder.decode(
            ProtoCodableKeyValueContainer<EntitlementContainer>.self, from: Self.encoder.encode(dict)
        ).values
    }

    // if `entitlements` and `setEntitlements` were the primitives, this function would end up performing
    // two entitlements() calls. This way we can optimize the number of calls.
    public mutating func updateEntitlements(_ block: (inout [Entitlement]) throws -> Void) throws {
        let old = try self.entitlements()

        var new = old
        try block(&new)

        let oldEnts = Dictionary(uniqueKeysWithValues: old.map { (type(of: $0).identifier, $0) })
        let newEnts = Dictionary(uniqueKeysWithValues: new.map { (type(of: $0).identifier, $0) })

        oldEnts.keys.filter { newEnts[$0] == nil }.forEach { dict[$0] = nil }
        newEnts.forEach { dict[$0] = AnyEncodable($1) }
    }

    public mutating func setEntitlements(_ new: [Entitlement]) throws {
        try updateEntitlements { $0 = new }
    }

}

extension Entitlements: Codable {

    public init(from decoder: Decoder) throws {
        self.dict = try decoder.singleValueContainer()
            .decode([String: CodableElement].self)
            .mapValues(AnyEncodable.init)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(dict)
    }

}
