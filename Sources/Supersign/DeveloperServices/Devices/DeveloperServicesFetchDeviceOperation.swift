//
//  DeveloperServicesFetchDeviceOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct DeveloperServicesFetchDeviceOperation: DeveloperServicesOperation {
    public let context: SigningContext
    public init(context: SigningContext) {
        self.context = context
    }

    public func perform() async throws -> DeveloperServicesDevice {
        let listRequest = DeveloperServicesListDevicesRequest(platform: context.platform, teamID: context.teamID)
        let devices = try await context.client.send(listRequest)
        if let device = devices.first(where: { $0.udid == self.context.udid }) {
            return device
        }

        let addRequest = DeveloperServicesAddDeviceRequest(
            platform: self.context.platform,
            teamID: self.context.teamID,
            udid: self.context.udid,
            name: self.context.deviceName
        )
        return try await context.client.send(addRequest)
    }

}
