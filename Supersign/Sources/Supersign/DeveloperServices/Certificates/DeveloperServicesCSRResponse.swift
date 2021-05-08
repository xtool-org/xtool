//
//  DeveloperServicesCSRResponse.swift
//  Supersign
//
//  Created by Kabir Oberai on 09/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesCSRResponse: Decodable {
    public struct ID: RawRepresentable, Decodable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }
    public let id: ID
    public let certificateID: DeveloperServicesCertificate.ID
    public let serialNumber: DeveloperServicesCertificate.SerialNumber
    public let status: String
    public let statusCode: Int
    public let platform: DeveloperServicesPlatform
    public let machineID: String?
    public let machineName: String?

    private enum CodingKeys: String, CodingKey {
        case id = "certRequestId"
        case certificateID = "certificateId"
        case serialNumber = "serialNum"
        case status = "statusString"
        case statusCode
        case platform = "csrPlatform"
        case machineID = "machineId"
        case machineName
    }
}
