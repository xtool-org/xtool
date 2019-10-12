//
//  DeveloperServicesCertificate.swift
//  Supercharge
//
//  Created by Kabir Oberai on 29/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesCertificate: Decodable {
    public struct ID: RawRepresentable, Decodable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }
    public let id: ID

    public struct SerialNumber: RawRepresentable, Decodable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }
    public let serialNumber: SerialNumber

    public struct CertificateType: Decodable {
        public let displayID: String
        public let name: String
        public let maxActive: Int

        private enum CodingKeys: String, CodingKey {
            case displayID = "certificateTypeDisplayId"
            case name
            case maxActive
        }
    }
    public let type: CertificateType

    public let status: String
    public let statusCode: Int
    public let expiry: Date
    public let platform: DeveloperServicesPlatform
    public let machineID: String?
    public let machineName: String?
    public let content: Certificate

    private enum CodingKeys: String, CodingKey {
        case id = "certificateId"
        case serialNumber
        case type = "certificateType"
        case status
        case statusCode
        case expiry = "expirationDate"
        case platform = "certificatePlatform"
        case content = "certContent"
        case machineID = "machineId"
        case machineName
    }
}
