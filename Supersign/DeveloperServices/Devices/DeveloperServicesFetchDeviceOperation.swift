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

    public func perform(completion: @escaping (Result<DeveloperServicesDevice, Error>) -> Void) {
        let request = DeveloperServicesListDevicesRequest(platform: context.platform, teamID: context.team.id)
        context.client.send(request) { result in
            guard let devices = result.get(withErrorHandler: completion) else { return }
            if let device = devices.first(where: { $0.udid == self.context.udid }) {
                return completion(.success(device))
            }

            let addRequest = DeveloperServicesAddDeviceRequest(
                platform: self.context.platform,
                teamID: self.context.team.id,
                udid: self.context.udid,
                name: self.context.deviceName
            )
            self.context.client.send(addRequest, completion: completion)
        }
    }

}
