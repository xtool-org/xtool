//
//  DTXTransport.swift
//  XKit
//
//  Opens the raw byte socket DTX runs over. Unlike the typed lockdown services elsewhere in
//  XKit/SwiftyMobileDevice (installation_proxy, mobile_image_mounter, ...), libimobiledevice has
//  no typed client for `com.apple.instruments.remoteserver`/`com.apple.testmanagerd.lockdown` --
//  DTX itself isn't implemented at the C level at all (confirmed by reading the actual installed
//  headers). So this talks to the raw
//  `idevice_connection_t` socket libimobiledevice exposes for exactly this purpose, conforming it
//  to SwiftyMobileDevice's existing `StreamingConnection` protocol (the same abstraction
//  `DebugserverClient` is built on) to reuse its send/receive helpers rather than reinventing
//  socket buffering.

import Foundation
import SwiftyMobileDevice
import libimobiledevice

/// The byte-transport surface `DTXConnection` actually needs -- abstracted out so it can run
/// over either a classic lockdown `idevice_connection_t` (`DTXTransport`, below) or a
/// tunnel-routed TCP connection to an RSD-discovered service like
/// `com.apple.dt.testmanagerd.remote` (`TunnelDTXTransport`, in `Testing/Tunnel/`) -- same
/// protocol, different iOS-version paths to reach it (see `TestManagerdSession`'s doc comment for
/// which path applies when).
protocol DTXByteTransport: Sendable {
    func send(_ data: Data) throws -> Int
    /// A per-attempt bounded read; implementations should return quickly (throwing an error
    /// `isTimeout` accepts) rather than blocking indefinitely, so `DTXConnection`'s read loop can
    /// keep checking whether it's been asked to stop.
    func receive(maxLength: Int, timeout: TimeInterval) throws -> Data
    func close()
    /// Whether `error` represents "no data arrived within the timeout" (retry) as opposed to a
    /// real connection failure (give up).
    func isTimeout(_ error: Swift.Error) -> Bool
}

struct IdeviceError: CAPIError {
    let raw: idevice_error_t
    init?(_ raw: idevice_error_t) {
        guard raw != IDEVICE_E_SUCCESS else { return nil }
        self.raw = raw
    }
}

func checkIdevice(_ raw: idevice_error_t) throws {
    if let error = IdeviceError(raw) { throw error }
}

/// A raw `idevice_connection_t` socket, conforming to `StreamingConnection` so it can reuse
/// `send(_:)`/`receive(maxLength:timeout:)`/`receiveAll(...)`.
///
/// `nonisolated(unsafe)` on the stored properties below matches the pattern every other
/// `LockdownService`-conforming client in SwiftyMobileDevice uses for its raw C handle/function
/// pointers (e.g. `MobileImageMounterClient.raw`) -- C pointers/function pointers aren't checked
/// for `Sendable` by the compiler, but concurrent access to a single `idevice_connection_t` is
/// already externally synchronized here (all sends/receives happen on `DTXConnection`, an actor).
struct DTXTransport: StreamingConnection {
    typealias Error = IdeviceError
    typealias Raw = idevice_connection_t

    nonisolated(unsafe) let raw: idevice_connection_t
    nonisolated(unsafe) let sendFunc: SendFunc = idevice_connection_send
    nonisolated(unsafe) let receiveFunc: ReceiveFunc = idevice_connection_receive
    nonisolated(unsafe) let receiveTimeoutFunc: ReceiveTimeoutFunc = idevice_connection_receive_timeout

    /// Opens a DTX-capable service (instruments or testmanagerd) and returns a connected
    /// transport. Enables SSL when the service descriptor reports it's required (both
    /// `com.apple.instruments.remoteserver.DVTSecureSocketProxy` and
    /// `com.apple.testmanagerd.lockdown.secure` do on modern iOS versions).
    static func connect(device: Device, service: LockdownClient.ServiceDescriptor) throws -> DTXTransport {
        var raw: idevice_connection_t?
        try checkIdevice(idevice_connect(device.raw, service.port, &raw))
        guard let raw else { throw CAPIGenericError.unexpectedNil }
        if service.isSSLEnabled {
            try checkIdevice(idevice_connection_enable_ssl(raw))
        }
        return DTXTransport(raw: raw)
    }

    func close() {
        idevice_disconnect(raw)
    }
}

extension DTXTransport: DTXByteTransport {
    func receive(maxLength: Int, timeout: TimeInterval) throws -> Data {
        try receive(maxLength: maxLength, timeout: TimeInterval?.some(timeout))
    }

    func isTimeout(_ error: Swift.Error) -> Bool {
        (error as? IdeviceError)?.raw == IDEVICE_E_TIMEOUT
    }
}
