//
//  DeveloperServicesCertificate.swift
//  Supercharge
//
//  Created by Kabir Oberai on 29/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesCertificate: Decodable, Sendable {
    public struct ID: RawRepresentable, Decodable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }
    public let id: ID

    public struct SerialNumber: RawRepresentable, Decodable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }

    public enum Kind: String, Decodable, CaseIterable, Sendable {
        case development = "DEVELOPMENT"
        case distribution = "DISTRIBUTION"
        case iOSDevelopment = "IOS_DEVELOPMENT"
        case iOSDistribution = "IOS_DISTRIBUTION"
        case macAppDistribution = "MAC_APP_DISTRIBUTION"
        case macInstallerDistribution = "MAC_INSTALLER_DISTRIBUTION"
        case developerIDKext = "DEVELOPER_ID_KEXT"
        case developerIDApplication = "DEVELOPER_ID_APPLICATION"
        case unknown

        public init(platform: DeveloperServicesPlatform) {
            switch platform {
            case .iOS: self = .iOSDevelopment
            default: self = .development
            }
        }

        public init(from decoder: Decoder) throws {
            let rawValue = try String(from: decoder)
            self = Self.allCases.first { $0.rawValue == rawValue } ?? .unknown
        }
    }

    public struct Attributes: Decodable, Sendable {
        public let serialNumber: SerialNumber
        public let name: String
        public let kind: Kind
        public let expiry: Date
        public let machineID: String?
        public let machineName: String?
        public let content: Certificate

        private enum CodingKeys: String, CodingKey {
            case serialNumber
            case name
            case kind = "certificateType"
            case expiry = "expirationDate"
            case content = "certificateContent"
            case machineID = "machineId"
            case machineName
        }
    }
    public let attributes: Attributes
}
