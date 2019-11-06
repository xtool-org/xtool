//
//  SigningContext.swift
//  Supersign
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct SigningContext {

    public let udid: String
    public let team: DeveloperServicesTeam
    public let signerImpl: SignerImpl
    public let platform: DeveloperServicesPlatform
    public let client: DeveloperServicesClient

    public init(
        udid: String,
        team: DeveloperServicesTeam,
        signerImpl: SignerImpl? = nil,
        platform: DeveloperServicesPlatform = .current,
        client: DeveloperServicesClient = .shared
    ) throws {
        self.udid = udid
        self.team = team
        self.signerImpl = try signerImpl ?? .first()
        self.platform = platform
        self.client = client
    }

}

#if canImport(UIKit)
import UIKit
#endif
extension SigningContext {
    public var deviceName: String {
        #if targetEnvironment(simulator)
        return "Simulator"
        #elseif canImport(UIKit)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current.localizedName ?? "Mac"
        #else
        return "Supercharge Client"
        #endif
    }
}
