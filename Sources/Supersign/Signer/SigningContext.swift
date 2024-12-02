//
//  SigningContext.swift
//  Supersign
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct SigningContext: Sendable {

    public let udid: String
    public let deviceName: String
    public let teamID: DeveloperServicesTeam.ID
    public let client: DeveloperServicesClient
    public let signingInfoManager: SigningInfoManager
    public let platform: DeveloperServicesPlatform
    public let signerImpl: SignerImpl

    public init(
        udid: String,
        deviceName: String,
        teamID: DeveloperServicesTeam.ID,
        client: DeveloperServicesClient,
        signingInfoManager: SigningInfoManager,
        platform: DeveloperServicesPlatform = .current,
        signerImpl: SignerImpl? = nil
    ) throws {
        self.udid = udid
        self.deviceName = deviceName
        self.teamID = teamID
        self.client = client
        self.signingInfoManager = signingInfoManager
        self.platform = platform
        self.signerImpl = try signerImpl ?? .first()
    }

}

#if canImport(UIKit)
import UIKit
#endif
extension SigningContext {
    public static var hostName: String {
        #if targetEnvironment(simulator)
        return "Simulator"
        #elseif canImport(UIKit)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Supercharge Client"
        #endif
    }
}
