//
//  DeveloperServicesListCertificatesRequest.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesListCertificatesRequest: DeveloperServicesRequest, Sendable {

    public typealias Response = [DeveloperServicesCertificate]
    public typealias Value = Response

    public var apiVersion: DeveloperServicesAPIVersion { DeveloperServicesAPIVersionV1() }
    public var methodOverride: String? { "GET" }

    public let teamID: DeveloperServicesTeam.ID
    public let certificateKind: DeveloperServicesCertificate.Kind

    public var action: String { "certificates" }
    public var parameters: [String: Any] {
        [
            "teamId": teamID.rawValue,
            "filter[certificateType]": certificateKind.rawValue
        ]
    }

    public init(teamID: DeveloperServicesTeam.ID, certificateKind: DeveloperServicesCertificate.Kind) {
        self.teamID = teamID
        self.certificateKind = certificateKind
    }

}
