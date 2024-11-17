//
//  Superconfig.swift
//  
//
//  Created by Kabir Oberai on 02/05/21.
//

import Foundation

public struct Superconfig: Codable {
    // Stuff that needs to come from the installer
    public let udid: String
    public let pairingKeys: Data
    public let deviceInfo: DeviceInfo

    // Stuff that can also be fetched in-app
    public let preferredTeamID: String
    public let preferredSigningInfo: SigningInfo?
    public let appleID: String
    public let provisioningData: ProvisioningData?
    public let token: DeveloperServicesLoginToken

    public init(
        udid: String,
        pairingKeys: Data,
        deviceInfo: DeviceInfo,
        preferredTeamID: String,
        preferredSigningInfo: SigningInfo?,
        appleID: String,
        provisioningData: ProvisioningData?,
        token: DeveloperServicesLoginToken
    ) {
        self.udid = udid
        self.pairingKeys = pairingKeys
        self.deviceInfo = deviceInfo
        self.preferredTeamID = preferredTeamID
        self.preferredSigningInfo = preferredSigningInfo
        self.appleID = appleID
        self.provisioningData = provisioningData
        self.token = token
    }

    public static let filename = "Superconfig.plist"
    public static let encoder = PropertyListEncoder()
    public func save(inAppDir appDir: URL) throws {
        try Self.encoder.encode(self).write(to: appDir.appendingPathComponent(Self.filename))
    }
}
