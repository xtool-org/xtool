//
//  TunnelDTXTransport.swift
//  XKit
//
//  Adapts `PosixTCPSocket` to `DTXByteTransport`, so `DTXConnection` (built for the classic
//  lockdown `idevice_connection_t` path in `DTXTransport.swift`) can run unmodified over an
//  RSD-discovered service reached through `CoreDeviceProxyTunnel` -- e.g.
//  `com.apple.dt.testmanagerd.remote` on iOS 17.4+, in place of `com.apple.testmanagerd.lockdown
//  [.secure]`. The DTX wire protocol itself (message framing, NSKeyedArchiver payloads, channel
//  semantics) is identical either way; only the byte transport underneath differs.
//

import Foundation

struct TunnelDTXTransport: DTXByteTransport {
    let socket: PosixTCPSocket

    /// Connects to an RSD-discovered service's port at the tunnel's server address. `port` comes
    /// from `RSDHandshakeResponse.port(for:)` (e.g. `"com.apple.dt.testmanagerd.remote"`).
    init(tunnel: CoreDeviceProxyTunnel, port: Int) throws {
        socket = try PosixTCPSocket(address: tunnel.address, port: port)
    }

    func send(_ data: Data) throws -> Int {
        try socket.send(data)
        return data.count
    }

    func receive(maxLength: Int, timeout: TimeInterval) throws -> Data {
        try socket.receive(maxLength: maxLength, timeoutMs: Int32(timeout * 1000))
    }

    func close() {
        socket.close()
    }

    func isTimeout(_ error: Swift.Error) -> Bool {
        (error as? PosixTCPSocketError) == .timeout
    }
}