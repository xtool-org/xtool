//
//  Connection.swift
//  Supersign
//
//  Created by Kabir Oberai on 15/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

#if os(iOS)
import USBMuxSim
import PortForwarding

public typealias PairingKeys = Data

private extension USBMuxSimulator {
    func performAtomically<T>(_ operation: (USBMuxSimulator) -> T) -> T {
        var value: T!
        __performAtomically { value = operation($0) }
        return value
    }

    func performAtomically<T>(_ operation: (USBMuxSimulator) throws -> T) throws -> T {
        var value: Result<T, Swift.Error>!
        __performAtomically { sim in
            value = Result { try operation(sim) }
        }
        return try value.get()
    }
}
#else
public typealias PairingKeys = Void
#endif

private class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

// there is guaranteed to be at most one Connection instance per udid
// at any moment, thanks to Connection.connection(...). Consequently
// there is at most one device per udid at any moment too.
public class Connection {

    public enum Error: Swift.Error {
        case portForwardingFailed
    }

    public struct Preferences {
        public let usePortForwarding: Bool
        public init(usePortForwarding: Bool = false) {
            self.usePortForwarding = usePortForwarding
        }
    }

    private static let label = "supersign"

    private static var connections: [String: WeakBox<Connection>] = [:]
    private static let connectionsQueue = DispatchQueue(label: "connections-queue")

    #if os(iOS)
    private var handle: Int32
    private let heartbeatHandler: HeartbeatHandler
    #endif
    private let udid: String
    public let device: Device
    public let client: LockdownClient
    public var preferences: Preferences

    private init(
        udid: String,
        pairingKeys: PairingKeys,
        preferences: Preferences,
        progress: (Double) -> Void
    ) throws {
        progress(0/4)

        self.preferences = preferences
        self.udid = udid

        #if os(iOS)
        let simulatedDevice: USBMuxSimulatedDevice
        if preferences.usePortForwarding {
            var ip = in_addr()
            guard usbmux_forwarded_ip(&ip) == 0 else {
                throw Error.portForwardingFailed
            }
            NSLog("[SuperUSB] %@", "Using port forwarded device with ip \(String(cString: inet_ntoa(ip)!))")
            simulatedDevice = PortForwardedDevice(ip: ip, udid: udid)
        } else {
            NSLog("[SuperUSB] %@", "Using VPN device")
            simulatedDevice = try VPNDevice(udid: udid)
        }
        simulatedDevice.pairingKeys = pairingKeys
        handle = USBMuxSimulator.shared.performAtomically { $0.register(device: simulatedDevice) }
        #endif
        progress(1/4)

        device = try Device(udid: udid)
        progress(2/4)

        client = try LockdownClient(device: device, label: Self.label, performHandshake: true)
        progress(3/4)

        #if os(iOS)
        heartbeatHandler = HeartbeatHandler(device: device, client: client)
        #endif
        progress(4/4)
    }

    public static func connection(
        forUDID udid: String,
        pairingKeys: PairingKeys,
        preferences: Preferences = .init(),
        progress: (Double) -> Void
    ) throws -> Connection {
        try connectionsQueue.sync {
            progress(0)
            if let conn = connections[udid]?.value {
                progress(1)
                return conn
            }
            let conn = try Connection(
                udid: udid,
                pairingKeys: pairingKeys,
                preferences: preferences,
                progress: progress
            )
            connections[udid] = WeakBox(conn)
            return conn
        }
    }

    deinit {
        // we could nil out connections[udid] here but that might lead to
        // weird race conditions against Connection.connection that seem
        // like a nightmare to diagnose, and storing an empty box for a
        // udid isn't much memory anyway
        #if os(iOS)
        heartbeatHandler.stop()
        _ = USBMuxSimulator.shared.performAtomically {
            $0.deregisterDevice(forHandle: handle)
        }
        #endif
    }

    public func startClient<T: LockdownService>(_ type: T.Type = T.self, sendEscrowBag: Bool = false) throws -> T {
        try .init(device: device, service: .init(client: client, type: type, sendEscrowBag: sendEscrowBag))
    }

}
