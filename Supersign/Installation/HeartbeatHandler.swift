//
//  HeartbeatHandler.swift
//  Supersign
//
//  Created by Kabir Oberai on 14/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

class HeartbeatHandler {

    private struct Error: Swift.Error {}

    private static let restartInterval: TimeInterval = 1
    private static let requestCommand = "Marco"
    private static let responseCommand = "Polo"

    // each handler should have its own heartbeat queue
    private let heartbeatQueue = DispatchQueue(
        label: "com.kabiroberai.Supersign.heartbeat-queue"
    )
    private(set) var isStopped = false

    let device: Device
    let client: LockdownClient
    init(device: Device, client: LockdownClient) {
        self.device = device
        self.client = client
        start()
    }

    private func beat(client: HeartbeatClient, idx: Int) throws {
        // allow a 30 second timeout for the first heartbeat
        let plist = try client.receive(timeout: idx == 0 ? 30 : 5)
        guard case let .dictionary(dict) = plist,
            case let .string(command) = dict["Command"],
            case let .integer(interval) = dict["Interval"],
            command == Self.requestCommand
            else { throw Error() }

        try client.send(.dictionary([
            "Command": .string(Self.responseCommand)
        ]))

        sleep(.init(interval))
    }

    private func start() {
        let heartbeatClient: HeartbeatClient
        do {
            heartbeatClient = try HeartbeatClient(device: device, service: .init(client: client))
        } catch {
            // we sleep instead of asyncAfter to allow the initial startHeartbeat
            // call to block until a connection is established
            let timeInterval = Self.restartInterval
            let sec = timeInterval.rounded(.down)
            let nsec = (timeInterval - sec) * 1_000_000_000
            var time = timespec(
                tv_sec: .init(sec),
                tv_nsec: .init(nsec)
            )
            nanosleep(&time, nil)
            start()
            return
        }

        self.heartbeatQueue.async { [weak self] in
            var idx = 0
            while true {
                // only retains `self` for this iteration. This way, if the reference to
                // the handler is dropped,
                guard let self = self, !self.isStopped else { break }
                do {
                    try self.beat(client: heartbeatClient, idx: idx)
                    idx += 1
                } catch {
                    // dispatching async should prevent stack overflows and allow the existing
                    // heartbeatClient to deinit
                    self.heartbeatQueue.asyncAfter(deadline: .now() + Self.restartInterval) {
                        self.start()
                    }
                    break
                }
            }
        }
    }

    func stop() {
        isStopped = true
    }

}
