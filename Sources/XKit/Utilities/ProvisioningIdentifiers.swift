//
//  ProvisioningIdentifiers.swift
//  XKit
//
//  Created by Kabir Oberai on 14/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

enum ProvisioningIdentifiers {}

extension ProvisioningIdentifiers {

    static let idPrefix = "XTL-"
    static let groupPrefix = "group."
    static let namePrefix = "XTool "

    static func sanitize(identifier: String) -> String {
        guard identifier.hasPrefix(Self.idPrefix) else { return identifier }
        return identifier.split(separator: ".").dropFirst().joined(separator: ".")
    }

    static func identifier(fromSanitized sanitized: String, context: SigningContext? = nil) -> String {
        let uuid = (context?.auth.identityID ?? UUID().uuidString).split(separator: "-")[0].uppercased()
        return "\(Self.idPrefix)\(uuid).\(sanitized)"
    }

    static func safeify(identifier: String) -> String {
        identifier.replacingOccurrences(of: ".", with: " ")
    }

    static func sanitize(groupID: DeveloperServicesAppGroup.GroupID) -> String {
        var id = groupID.rawValue
        if id.hasPrefix(Self.groupPrefix) { id.removeFirst(Self.groupPrefix.count) }
        return sanitize(identifier: id)
    }

    static func groupID(fromSanitized sanitized: String, context: SigningContext? = nil) -> DeveloperServicesAppGroup.GroupID {
        .init(rawValue: "\(Self.groupPrefix)\(identifier(fromSanitized: sanitized, context: context))")
    }

    static func groupName(fromSanitized sanitized: String) -> String {
        "\(Self.namePrefix)group \(safeify(identifier: sanitized))"
    }

    static func appName(fromSanitized sanitized: String) -> String {
        "\(Self.namePrefix)\(safeify(identifier: sanitized))"
    }

}
