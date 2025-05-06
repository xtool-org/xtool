//
//  DeveloperServicesFetchDeviceOperation.swift
//  Supersign
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import DeveloperAPI

public struct DeveloperServicesFetchDeviceOperation: DeveloperServicesOperation {
    public let context: SigningContext
    public init(context: SigningContext) {
        self.context = context
    }

    public func perform() async throws -> Components.Schemas.Device {
        let devices = try await context.developerAPIClient.devicesGetCollection().ok.body.json.data

        if let device = devices.first(where: { $0.attributes?.udid == self.context.udid }) {
            return device
        }

        let response = try await context.developerAPIClient.devicesCreateInstance(
            body: .json(.init(data: .init(
                _type: .devices,
                attributes: .init(
                    name: self.context.deviceName,
                    platform: .ios,
                    udid: self.context.udid
                )
            )))
        )

        return try response.created.body.json.data
    }

}
