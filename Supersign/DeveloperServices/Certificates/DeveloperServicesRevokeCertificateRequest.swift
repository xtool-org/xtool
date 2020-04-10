//
//  DeveloperServicesRevokeCertificateRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

// swiftlint:disable:next type_name
public struct DeveloperServicesRevokeCertificateRequest: DeveloperServicesRequest {

    public typealias Response = EmptyResponse
    public typealias Value = Response

    public var apiVersion: DeveloperServicesAPIVersion { DeveloperServicesAPIVersionV1() }
    public var methodOverride: String? { "DELETE" }

    public let teamID: DeveloperServicesTeam.ID
    public let certificateID: DeveloperServicesCertificate.ID

    public var action: String { "certificates/\(certificateID.rawValue)" }
    public var parameters: [String: Any] {
        ["teamId": teamID.rawValue]
    }

    public init(
        teamID: DeveloperServicesTeam.ID,
        certificateID: DeveloperServicesCertificate.ID
    ) {
        self.teamID = teamID
        self.certificateID = certificateID
    }

}
