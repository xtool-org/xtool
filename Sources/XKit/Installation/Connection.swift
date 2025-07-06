//
//  Connection.swift
//  XKit
//
//  Created by Kabir Oberai on 15/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

private struct Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
extension Weak: Sendable where T: Sendable {}

// there is guaranteed to be at most one Connection instance per (udid, preferences)
// at any moment, thanks to the object pool. Consequently there is at most one device
// per (udid, preferences) at any moment too.
public actor Connection {

    public enum LookupHandler: Hashable, Sendable {
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

    public struct Preferences: Hashable, Sendable {
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

    private static let label = "xtool"
    private static let pool = WeakPool<ConnectionDescriptor, Connection, Error>()

    private var handle: AnyObject?
    private let heartbeatHandler: HeartbeatHandler?
    private let udid: String
    public let device: Device
    public let client: LockdownClient
    public let preferences: Preferences

    private init(
        udid: String,
        preferences: Preferences,
        progress: (Double) -> Void
    ) async throws {
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

        #if os(iOS)
        progress(3/4)
        heartbeatHandler = try await HeartbeatHandler(device: device, client: client)
        #else
        heartbeatHandler = nil
        #endif

        progress(4/4)
    }

    public static func connection(
        forUDID udid: String,
        preferences: Preferences,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Connection {
        progress(0)
        defer { progress(1) }
        return try await Self.pool.value(
            key: ConnectionDescriptor(udid: udid, preferences: preferences)
        ) {
            try await Connection(udid: udid, preferences: preferences, progress: progress)
        }
    }

    deinit {
        heartbeatHandler?.stop()
        // we could nil out connections[udid] here but that might lead to
        // weird race conditions against Connection.connection that seem
        // like a nightmare to diagnose, and storing an empty box for a
        // udid isn't much memory anyway
    }

    public func startClient<T: LockdownService>(_ type: T.Type = T.self, sendEscrowBag: Bool = false) throws -> T {
        try .init(device: device, service: .init(client: client, type: type, sendEscrowBag: sendEscrowBag))
    }

}

#if compiler(<6.2)
private typealias SendableMetatype = Any
#endif

private actor WeakPool<Key: Hashable & SendableMetatype, Value: AnyObject & Sendable, Failure: Error> {
    init() {}

    private var pendingValues: [Key: Task<Result<Value, Failure>, Never>] = [:]
    private var existingValues: [Key: Weak<Value>] = [:]

    func value(
        key: Key,
        create: @escaping @Sendable () async throws(Failure) -> Value
    ) async throws(Failure) -> Value {
        if let pending = pendingValues[key] {
            return try await pending.value.get()
        }

        if let existing = existingValues[key] {
            if let existingValue = existing.value {
                return existingValue
            } else {
                existingValues[key] = nil
            }
        }

        let task = Task { () -> Result<Value, Failure> in
            do throws(Failure) {
                let connection = try await create()
                existingValues[key] = Weak(connection)
                pendingValues[key] = nil
                return .success(connection)
            } catch {
                return .failure(error)
            }
        }
        pendingValues[key] = task

        return try await task.value.get()
    }
}

public protocol ConnectionLookupHandler: Hashable, Sendable {
    func createHandle() throws -> AnyObject
}
