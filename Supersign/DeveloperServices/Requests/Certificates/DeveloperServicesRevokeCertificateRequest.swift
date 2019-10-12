//
//  DeveloperServicesRevokeCertificateRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

// swiftlint:disable:next type_name
public struct DeveloperServicesRevokeCertificateRequest: DeveloperServicesPlatformRequest {

    public struct Response: Decodable {}
    public typealias Value = Response

    public let platform: DeveloperServicesPlatform
    public let teamID: DeveloperServicesTeam.ID
    public let serialNumber: DeveloperServicesCertificate.SerialNumber

    var subAction: String { return "revokeDevelopmentCert" }
    var subParameters: [String: Any] {
        return ["teamId": teamID.rawValue, "serialNumber": serialNumber.rawValue]
    }

    init(
        platform: DeveloperServicesPlatform,
        teamID: DeveloperServicesTeam.ID,
        serialNumber: DeveloperServicesCertificate.SerialNumber
    ) {
        self.platform = platform
        self.teamID = teamID
        self.serialNumber = serialNumber
    }

}
