//
//  RSDHandshake.swift
//  XKit
//
//  Remote Service Discovery (RSD): iOS 17+'s replacement for classic lockdown service lookup.
//  Once a `RemoteXPCConnection` is up (either pre-tunnel, over the device's untrusted USB network
//  interface, or post-tunnel, over the TUN-routed interface -- this type doesn't care which), the
//  device pushes a single unsolicited "Handshake" message listing every available service and its
//  port. Structured after the documented, working reference in go-ios's `ios/rsd.go` (MIT -- read
//  for the message shape, rewritten from scratch in Swift here; same clean-room approach as the
//  rest of this directory).
//

import Foundation

public struct RSDServiceEntry: Sendable {
    public let port: UInt32
}

public struct RSDHandshakeResponse: Sendable {
    public let udid: String
    public let services: [String: RSDServiceEntry]

    public func port(for service: String) -> Int? {
        guard let entry = services[service] else { return nil }
        return Int(entry.port)
    }
}

enum RSDError: Swift.Error {
    case missingUDID
    case unexpectedMessageType
    case malformedServiceEntry(String)
}

public enum RSDHandshake {
    /// Blocks until the device's `Handshake` message arrives and parses it. Must be called
    /// immediately after `RemoteXPCConnection` is constructed -- the device sends this
    /// unprompted, as the very first thing on the connection.
    public static func perform(over connection: RemoteXPCConnection) throws -> RSDHandshakeResponse {
        guard let message = try connection.receiveOnClientServerStream() else {
            throw RSDError.unexpectedMessageType
        }
        guard case .string(let udid)? = dig(message, "Properties", "UniqueDeviceID") else {
            throw RSDError.missingUDID
        }
        guard case .string("Handshake")? = message["MessageType"] else {
            throw RSDError.unexpectedMessageType
        }
        guard case .dictionary(let servicesRaw)? = message["Services"] else {
            throw RSDError.unexpectedMessageType
        }
        var services: [String: RSDServiceEntry] = [:]
        for (name, entry) in servicesRaw {
            guard
                case .dictionary(let entryDict) = entry,
                case .string(let portString)? = entryDict["Port"],
                let port = UInt32(portString)
            else {
                throw RSDError.malformedServiceEntry(name)
            }
            services[name] = RSDServiceEntry(port: port)
        }
        return RSDHandshakeResponse(udid: udid, services: services)
    }

    private static func dig(_ dict: [String: RemoteXPCValue], _ path: String...) -> RemoteXPCValue? {
        var current: RemoteXPCValue = .dictionary(dict)
        for key in path {
            guard case .dictionary(let d) = current, let next = d[key] else { return nil }
            current = next
        }
        return current
    }
}
