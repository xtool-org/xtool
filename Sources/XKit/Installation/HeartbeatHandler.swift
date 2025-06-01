//
//  HeartbeatHandler.swift
//  XKit
//
//  Created by Kabir Oberai on 14/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice
import ConcurrencyExtras

public actor HeartbeatHandler {
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

    private let device: Device
    private let client: LockdownClient
    private var task: Task<Void, Never>?

    public init(device: Device, client: LockdownClient) async throws {
        self.device = device
        self.client = client

        let initialClient = try await createHeartbeatClient()

        task = Task { [weak self] in
            var client = initialClient
            for iteration in 0... {
                // only retains `self` for this iteration. This way, if the reference to
                // the handler is dropped, the heartbeat stops
                guard let self = self, !Task.isCancelled else { break }

                do {
                    try await beat(client: client, iteration: iteration)
                } catch {
                    NSLog("%@", "Heartbeat failed: \(error)" as NSString)
                    do {
                        try await Task.sleep(seconds: Self.restartInterval)
                        client = try await createHeartbeatClient()
                    } catch {
                        return // cancelled
                    }
                }
            }
        }
    }

    private func createHeartbeatClient() async throws -> HeartbeatClient {
        while true {
            do {
                return try HeartbeatClient(
                    device: device,
                    service: .init(client: client, type: HeartbeatClient.self)
                )
            } catch {
                try await Task.sleep(seconds: Self.restartInterval)
            }
        }
    }

    // no need for a custom deinit because the `guard let self = self` in the loop stops it
    // when the handler deinits

    private func beat(client: HeartbeatClient, iteration: Int) async throws {
        // allow a 30 second timeout for the first heartbeat
        let received = try client.receive(
            ReceivedPacket.self,
            timeout: iteration == 0 ? Self.initialTimeout : Self.repeatedTimeout
        )
        guard received.command == .marco else { throw Error() }

        try client.send(SentPacket(command: .polo))

        try? await Task.sleep(seconds: Double(received.interval))
    }

    nonisolated public func stop() {
        Task { await task?.cancel() }
    }
}
