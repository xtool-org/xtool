//
//  HeartbeatHandler.swift
//  Supersign
//
//  Created by Kabir Oberai on 14/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice
import ConcurrencyExtras

public final class HeartbeatHandler: Sendable {
    private struct Error: Swift.Error {}

    private struct ReceivedPacket: Decodable {
        enum Command: String, Decodable {
            case marco = "Marco"
        }

        let command: Command
        let interval: Int

        private enum CodingKeys: String, CodingKey {
            case command = "Command"
            case interval = "Interval"
        }
    }

    private struct SentPacket: Encodable {
        enum Command: String, Encodable {
            case polo = "Polo"
        }

        let command: Command

        private enum CodingKeys: String, CodingKey {
            case command = "Command"
        }
    }

    // the duration to wait after a failed heartbeat, before restarting
    private static let restartInterval: TimeInterval = 1
    // the timeout when receiving the first heartbeat packet
    private static let initialTimeout: TimeInterval = 30
    // the timeout when receiving subsequent heartbeat packets
    private static let repeatedTimeout: TimeInterval = 5

    // each handler should have its own heartbeat queue
    private let heartbeatQueue = DispatchQueue(
        label: "com.kabiroberai.Supersign.heartbeat-queue"
    )
    private let isStopped = LockIsolated(false)

    private let device: Device
    private let client: LockdownClient
    public init(device: Device, client: LockdownClient) {
        self.device = device
        self.client = client
        start()
    }

    // no need for a custom deinit because the `guard let self = self` in the loop stops it
    // when the handler deinits

    private func beat(client: HeartbeatClient, iteration: Int) throws {
        // allow a 30 second timeout for the first heartbeat
        let received = try client.receive(
            ReceivedPacket.self,
            timeout: iteration == 0 ? Self.initialTimeout : Self.repeatedTimeout
        )
        guard received.command == .marco else { throw Error() }

        try client.send(SentPacket(command: .polo))

        Thread.sleep(forTimeInterval: .init(received.interval))
    }

    // TODO: Separate initial establishment phase (blocking) from loop
    // (non-blocking) and throw during initial phase if too many failed
    // attempts. Also maybe try to eliminate recursion to avoid relying
    // on TCO which is not deterministically applied.
    private func start() {
        let heartbeatClient: HeartbeatClient
        do {
            heartbeatClient = try HeartbeatClient(device: device, service: .init(client: client, type: HeartbeatClient.self))
        } catch {
            // we sleep instead of asyncAfter to allow the initial startHeartbeat
            // call to block until a connection is established
            Thread.sleep(forTimeInterval: Self.restartInterval)
            start()
            return
        }

        self.heartbeatQueue.async { [weak self] in
            for iteration in 0... {
                // only retains `self` for this iteration. This way, if the reference to
                // the handler is dropped, the heartbeat stops
                guard let self = self else { break }

                do {
                    guard !self.isStopped.value else { break }
                }

                do {
                    try self.beat(client: heartbeatClient, iteration: iteration)
                } catch {
                    "Heartbeat failed: \(error)".withCString {
                        NSLog("%s", $0)
                    }
                    // dispatching async should prevent stack overflows.
                    // We return to break out of the current loop.
                    return self.heartbeatQueue.asyncAfter(deadline: .now() + Self.restartInterval) {
                        self.start()
                    }
                }
            }
        }
    }

    public func stop() {
        self.isStopped.setValue(true)
    }
}
