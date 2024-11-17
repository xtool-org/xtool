//
//  Connection.swift
//  Supersign
//
//  Created by Kabir Oberai on 15/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

private class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

// there is guaranteed to be at most one Connection instance per (udid, preferences)
// at any moment, thanks to Connection.connection(...). Consequently
// there is at most one device per (udid, preferences) at any moment too.
public class Connection {

    public enum LookupHandler: Hashable {
        case system(LookupMode)
        case custom(any ConnectionLookupHandler)

        public static func == (lhs: LookupHandler, rhs: LookupHandler) -> Bool {
            switch (lhs, rhs) {
            case (.system(let l), .system(let r)):
                l == r
            case (.custom(let l), .custom(let r)):
                AnyHashable(l) == AnyHashable(r)
            default:
                false
            }
        }

        public func hash(into hasher: inout Hasher) {
            switch self {
            case .system(let mode):
                hasher.combine(ObjectIdentifier(LookupMode.self))
                hasher.combine(mode)
            case .custom(let handler):
                hasher.combine(ObjectIdentifier(type(of: handler)))
                hasher.combine(handler)
            }
        }
    }

    public struct Preferences: Hashable {
        public var lookupHandler: LookupHandler

        public init(lookupMode: LookupMode) {
            self.lookupHandler = .system(lookupMode)
        }

        public init(customLookupHandler: any ConnectionLookupHandler) {
            self.lookupHandler = .custom(customLookupHandler)
        }

        public init(lookupHandler: LookupHandler) {
            self.lookupHandler = lookupHandler
        }
    }

    private struct ConnectionDescriptor: Hashable {
        let udid: String
        let preferences: Preferences
    }

    private static let label = "supersign"

    private static var connections: [ConnectionDescriptor: WeakBox<Connection>] = [:]
    private static let connectionsQueue = DispatchQueue(label: "connections-queue")

    private var handle: AnyObject?
    private let heartbeatHandler: HeartbeatHandler
    private let udid: String
    public let device: Device
    public let client: LockdownClient
    public let preferences: Preferences

    private init(
        udid: String,
        preferences: Preferences,
        progress: (Double) -> Void
    ) throws {
        progress(0/4)

        self.preferences = preferences
        self.udid = udid

        switch preferences.lookupHandler {
        case .system(let lookupMode):
            device = try Device(udid: udid, lookupMode: lookupMode)
        case .custom(let lookupHandler):
            handle = try lookupHandler.createHandle()
            progress(1/4)
            device = try Device(udid: udid)
        }

        progress(2/4)

        client = try LockdownClient(device: device, label: Self.label, performHandshake: true)

        progress(3/4)
        heartbeatHandler = HeartbeatHandler(device: device, client: client)

        progress(4/4)
    }

    public static func connection(
        forUDID udid: String,
        preferences: Preferences,
        progress: (Double) -> Void
    ) throws -> Connection {
        let descriptor = ConnectionDescriptor(udid: udid, preferences: preferences)
        return try connectionsQueue.sync {
            progress(0)
            if let conn = connections[descriptor]?.value {
                progress(1)
                return conn
            }
            let conn = try Connection(
                udid: udid,
                preferences: preferences,
                progress: progress
            )
            connections[descriptor] = WeakBox(conn)
            return conn
        }
    }

    deinit {
        heartbeatHandler.stop()
        // we could nil out connections[udid] here but that might lead to
        // weird race conditions against Connection.connection that seem
        // like a nightmare to diagnose, and storing an empty box for a
        // udid isn't much memory anyway
    }

    public func startClient<T: LockdownService>(_ type: T.Type = T.self, sendEscrowBag: Bool = false) throws -> T {
        try .init(device: device, service: .init(client: client, type: type, sendEscrowBag: sendEscrowBag))
    }

}

public protocol ConnectionLookupHandler: Hashable {
    func createHandle() throws -> AnyObject
}
