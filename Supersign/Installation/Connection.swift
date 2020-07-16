//
//  Connection.swift
//  Supersign
//
//  Created by Kabir Oberai on 15/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

public class Connection {

    private static let label = "supersign"

    public private(set) var isClosed = false

    private let usbmuxHandler: USBMuxHandler
    public let device: Device
    public let client: LockdownClient
    private let heartbeatHandler: HeartbeatHandler

    public init(udid: String, pairingKeys: PairingKeys, progress: (Double) -> Void) throws {
        progress(0/4)

        usbmuxHandler = try USBMuxHandler(udid: udid, pairingKeys: pairingKeys)
        progress(1/4)

        device = try Device(udid: udid)
        progress(2/4)

        client = try LockdownClient(device: device, label: Self.label, performHandshake: true)
        progress(3/4)

        heartbeatHandler = HeartbeatHandler(device: device, client: client)
        progress(4/4)
    }

    deinit { close() }

    public func close() {
        guard !isClosed else { return }
        isClosed = true

        heartbeatHandler.stop()
        usbmuxHandler.stop()
    }

    public func startClient<T: LockdownService>(_ type: T.Type = T.self, sendEscrowBag: Bool = false) throws -> T {
        try .init(device: device, service: .init(client: client, sendEscrowBag: sendEscrowBag))
    }

}
