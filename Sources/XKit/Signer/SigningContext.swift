//
//  SigningContext.swift
//  XKit
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import DeveloperAPI

public struct SigningContext: Sendable {

    public let udid: String
    public let deviceName: String
    public let auth: DeveloperAPIAuthData
    public let signer: Signer

    public var developerAPIClient: DeveloperAPIClient {
        DeveloperAPIClient(auth: auth)
    }

    public init(
        udid: String,
        deviceName: String,
        auth: DeveloperAPIAuthData,
        signer: Signer? = nil
    ) throws {
        self.udid = udid
        self.deviceName = deviceName
        self.auth = auth
        self.signer = try signer ?? .first()
    }

}

#if canImport(UIKit)
import UIKit
#endif
extension SigningContext {
    @MainActor public static var hostName: String {
        #if targetEnvironment(simulator)
        return "Simulator"
        #elseif canImport(UIKit)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "XTool Client"
        #endif
    }
}
