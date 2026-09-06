//
//  CoreDeviceProxyTunnel.swift
//  XKit
//
//  Establishes the iOS 17.4+ RSD tunnel via the lockdown-exposed `CoreDeviceProxy` service --
//  the simple path that reuses the *existing* trusted USB pairing (already handled by
//  `SwiftyMobileDevice`/lockdown elsewhere in this project) instead of the older, much larger
//  SRP6a/RemoteXPC pairing handshake iOS 17.0-17.3 required. Structured after the documented,
//  working reference in go-ios's `ios/tunnel/tunnel_lockdown.go` (MIT -- read for the handshake
//  and packet-forwarding shape, rewritten from scratch in Swift here; same clean-room approach as
//  the rest of this directory).
//
//  Sequence:
//    1. Open the `com.apple.internal.devicecompute.CoreDeviceProxy` lockdown service.
//    2. Exchange CDTunnel parameters over it (`"CDTunnel\0"` + 1-byte length + JSON), getting
//       back the tunnel's IPv6 addressing plus the address/port to reach RSD at once the tunnel
//       is up.
//    3. Create and configure a kernel TUN device with the client-side address (`TUNDevice.swift`).
//    4. Pump raw IPv6 packets bidirectionally between the lockdown connection (which frames
//       packets as `[40-byte IPv6 header][payload]` back-to-back on a plain byte stream) and the
//       TUN device (which is already packet-boundary-preserving, one packet per read/write).
//

import Foundation
import SwiftyMobileDevice
import libimobiledevice

struct CoreDeviceProxyTransport: StreamingConnection {
    typealias Error = IdeviceError
    typealias Raw = idevice_connection_t

    nonisolated(unsafe) let raw: idevice_connection_t
    nonisolated(unsafe) let sendFunc: SendFunc = idevice_connection_send
    nonisolated(unsafe) let receiveFunc: ReceiveFunc = idevice_connection_receive
    nonisolated(unsafe) let receiveTimeoutFunc: ReceiveTimeoutFunc = idevice_connection_receive_timeout
    /// One per `CoreDeviceProxyTransport` instance, not shared -- see `CoreDeviceProxyIOState`'s
    /// doc comment for why this needs to exist at all, and this property's own doc comment on
    /// why it must NOT be a single process-wide global (which is how it was originally written).
    let ioState = CoreDeviceProxyIOState()

    static func connect(device: Device, service: LockdownClient.ServiceDescriptor) throws -> CoreDeviceProxyTransport {
        var raw: idevice_connection_t?
        try checkIdevice(idevice_connect(device.raw, service.port, &raw))
        guard let raw else { throw CAPIGenericError.unexpectedNil }
        if service.isSSLEnabled {
            try checkIdevice(idevice_connection_enable_ssl(raw))
        }
        return CoreDeviceProxyTransport(raw: raw)
    }

    func close() {
        idevice_disconnect(raw)
    }
}

struct CDTunnelParameters: Sendable {
    let serverAddress: String
    let serverRSDPort: UInt64
    let clientAddress: String
    let clientMTU: UInt64
}

public enum CDTunnelError: Swift.Error {
    case serviceUnavailable
    case malformedResponse
    case malformedPacketStream
    case stopped
}

private let cdTunnelPollTimeout: TimeInterval = 0.2

/// Serializes every send/receive/close on the raw `idevice_connection_t` `CoreDeviceProxyTransport`
/// wraps, *and* tracks whether it's been closed -- both checked and mutated atomically inside the
/// same `queue.sync` block as the actual I/O. This is the piece a first pass at this fix (checking
/// a `shouldStop` closure *before* entering the queue) got wrong: `CoreDeviceProxyTransport` is a
/// bare struct with no closed-tracking of its own, so a `sendSerialized`/`receiveExact` call could
/// pass its pre-queue `shouldStop()` check, then lose a race to `close()` for the queue itself --
/// `close()` runs first, `idevice_disconnect`s the connection, and the pending send/receive then
/// executes on a freed connection. Confirmed via a real heap-corruption crash (`free(): chunks in
/// smallbin corrupted`, `double free or corruption`, and a SIGSEGV, non-deterministically across
/// runs -- the hallmark of a genuine data race) during real-device testing, and pinned down via
/// fine-grained per-operation logging showing the crash landing immediately after `close()` and an
/// in-flight `sendSerialized` were both active. Mirrors `TUNDevice`'s `ioQueue`, which already got
/// this right (its `isClosed` check lives inside the same `ioQueue.sync` block as its I/O).
///
/// - Important: one instance per `CoreDeviceProxyTransport` (see that type's `ioState` property),
///   *not* a single process-wide singleton -- this was originally a `private let` at file scope,
///   which meant every tunnel in the process shared one `closed` flag: closing the first tunnel
///   opened (e.g. after `--repeat`'s first iteration) permanently poisoned every subsequent
///   tunnel's I/O with `CDTunnelError.stopped`, even freshly-connected ones. Confirmed against
///   real hardware (this session): `xtool test --repeat 2` worked on iteration 1 and failed
///   immediately on iteration 2 with exactly that error.
final class CoreDeviceProxyIOState: @unchecked Sendable {
    let queue = DispatchQueue(label: "xtool.tunnel.io")
    /// Guarded by `queue` -- only ever read/written from inside a `queue.sync` block.
    var closed = false
}

extension CoreDeviceProxyTransport {
    /// Blocks until exactly `count` bytes are read, retrying on the timeout error
    /// `DTXConnection`'s own read loop already established the convention for (see
    /// `DTXConnection.receiveChunk`'s doc comment) -- a short per-attempt timeout so this can't
    /// block forever on a connection that's silently gone away. Each individual receive attempt
    /// (not the whole retry loop) runs inside the shared queue so a concurrent `send` on the same
    /// connection can interleave between attempts rather than being blocked out entirely.
    fileprivate func receiveExact(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(capacity: count)
        while data.count < count {
            let result = ioState.queue.sync { () -> Result<Data, Swift.Error> in
                guard !ioState.closed else { return .failure(CDTunnelError.stopped) }
                return Result { try receive(maxLength: count - data.count, timeout: cdTunnelPollTimeout) }
            }
            do {
                let chunk = try result.get()
                guard !chunk.isEmpty else { throw CDTunnelError.malformedPacketStream }
                data += chunk
            } catch let error as IdeviceError where error.raw == IDEVICE_E_TIMEOUT {
                continue
            }
        }
        return data
    }

    /// Serialized counterpart to `receiveExact` for the write side.
    fileprivate func sendSerialized(_ data: Data) throws {
        try ioState.queue.sync {
            guard !ioState.closed else { throw CDTunnelError.stopped }
            _ = try send(data)
        }
    }

    /// Marks this transport's state closed and disconnects, both inside the same `queue.sync`
    /// block so no `receiveExact`/`sendSerialized` call already past its `closed` check can still
    /// be in-flight when `close()` (the `StreamingConnection` requirement, e.g.
    /// `idevice_disconnect`) actually runs.
    fileprivate func closeSerialized(_ close: () -> Void) {
        ioState.queue.sync {
            guard !ioState.closed else { return }
            ioState.closed = true
            close()
        }
    }
}

enum CDTunnelHandshake {
    private static let magicPrefix = Data("CDTunnel\0".utf8)

    static func exchange(over connection: CoreDeviceProxyTransport) throws -> CDTunnelParameters {
        let request: [String: Any] = ["type": "clientHandshakeRequest", "mtu": 1280]
        let requestBody = try JSONSerialization.data(withJSONObject: request)
        guard requestBody.count <= 255 else { throw CDTunnelError.malformedResponse }

        var frame = magicPrefix
        frame.append(UInt8(requestBody.count))
        frame += requestBody
        _ = try connection.send(frame)

        let header = try connection.receiveExact(magicPrefix.count + 1)
        guard header.starts(with: magicPrefix) else { throw CDTunnelError.malformedResponse }
        let bodyLength = Int(header[header.index(before: header.endIndex)])
        let body = try connection.receiveExact(bodyLength)

        guard
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
            let serverAddress = json["serverAddress"] as? String,
            let serverRSDPort = json["serverRSDPort"] as? NSNumber,
            let clientParameters = json["clientParameters"] as? [String: Any],
            let clientAddress = clientParameters["address"] as? String,
            let clientMTU = clientParameters["mtu"] as? NSNumber
        else {
            throw CDTunnelError.malformedResponse
        }

        return CDTunnelParameters(
            serverAddress: serverAddress,
            serverRSDPort: serverRSDPort.uint64Value,
            clientAddress: clientAddress,
            clientMTU: clientMTU.uint64Value
        )
    }
}

/// A live tunnel to a device: `address`/`rsdPort` are where RSD (and, after an RSD lookup,
/// `com.apple.dt.testmanagerd.remote`) are reachable over the TUN interface this creates. Call
/// `close()` when done to tear down the TUN device and the underlying lockdown connection.
public final class CoreDeviceProxyTunnel: @unchecked Sendable {
    static let serviceName = "com.apple.internal.devicecompute.CoreDeviceProxy"

    public let address: String
    public let rsdPort: Int

    private let transport: CoreDeviceProxyTransport
    private let tun: TUNDevice
    private let stopLock = NSLock()
    private var stopped = false

    private init(address: String, rsdPort: Int, transport: CoreDeviceProxyTransport, tun: TUNDevice) {
        self.address = address
        self.rsdPort = rsdPort
        self.transport = transport
        self.tun = tun
    }

    /// Opens the tunnel end to end: lockdown service -> CDTunnel handshake -> TUN device ->
    /// background forwarding threads. `connection.client` must already have an active,
    /// established pairing with the device (the same one every other lockdown service in this
    /// project relies on) -- no separate SRP/RemoteXPC pairing is performed.
    public static func connect(connection: Connection) throws -> CoreDeviceProxyTunnel {
        var descriptor: lockdownd_service_descriptor_t?
        let status = lockdownd_start_service(connection.client.raw, serviceName, &descriptor)
        guard status == LOCKDOWN_E_SUCCESS, let descriptor else {
            // e.g. iOS < 17.4, which doesn't expose this service at all -- this device needs the
            // classic testmanagerd.lockdown path (`TestManagerdSession`), not this tunnel.
            throw CDTunnelError.serviceUnavailable
        }
        let serviceDescriptor = LockdownClient.ServiceDescriptor(raw: descriptor)
        let transport = try CoreDeviceProxyTransport.connect(device: connection.device, service: serviceDescriptor)

        let parameters: CDTunnelParameters
        do {
            parameters = try CDTunnelHandshake.exchange(over: transport)
        } catch {
            transport.closeSerialized { transport.close() }
            throw error
        }

        let tun: TUNDevice
        do {
            // matches go-ios's own admitted simplification (its comment: "TODO: could be derived
            // from the netmask provided by the device") -- the device always hands back a /64.
            tun = try TUNDevice(
                address: parameters.clientAddress,
                prefixLength: 64,
                mtu: UInt32(parameters.clientMTU)
            )
        } catch {
            transport.closeSerialized { transport.close() }
            throw error
        }

        let tunnel = CoreDeviceProxyTunnel(
            address: parameters.serverAddress,
            rsdPort: Int(parameters.serverRSDPort),
            transport: transport,
            tun: tun
        )
        tunnel.startForwarding(mtu: Int(parameters.clientMTU))
        return tunnel
    }

    private func shouldStop() -> Bool {
        stopLock.withLock { stopped }
    }

    public func close() {
        stopLock.withLock {
            guard !stopped else { return }
            stopped = true
        }
        tun.close()
        transport.closeSerialized { transport.close() }
    }

    deinit {
        close()
    }

    /// Spins up the two forwarding directions on dedicated `Thread`s, not `Task.detached` --
    /// same reasoning as `DTXConnection.start()`'s doc comment: these loops block on synchronous
    /// I/O (a lockdown `idevice_connection_t` receive and a TUN `read(2)`) for as long as the
    /// tunnel is open, and parking that on the cooperative thread pool would starve unrelated
    /// async work elsewhere in the process.
    private func startForwarding(mtu: Int) {
        let deviceToTUN = Thread { [weak self] in self?.forwardDeviceToTUN(mtu: mtu) }
        deviceToTUN.name = "xtool.tunnel.deviceToTUN"
        deviceToTUN.start()

        let tunToDevice = Thread { [weak self] in self?.forwardTUNToDevice(mtu: mtu) }
        tunToDevice.name = "xtool.tunnel.tunToDevice"
        tunToDevice.start()
    }

    /// The lockdown connection is a plain byte stream with no packet framing of its own, so each
    /// IPv6 packet has to be pulled off by reading its fixed 40-byte header, checking the version
    /// nibble, then reading exactly `payloadLength` (from the header's byte 4-5, big-endian) more
    /// bytes -- mirrors go-ios's `forwardTCPToInterface`.
    private func forwardDeviceToTUN(mtu: Int) {
        let ipv6HeaderLength = 40
        while !shouldStop() {
            do {
                let header = try transport.receiveExact(ipv6HeaderLength)
                guard header[header.startIndex] >> 4 == 6 else { throw CDTunnelError.malformedPacketStream }
                let payloadLength = Int(header[header.index(header.startIndex, offsetBy: 4)]) << 8
                    | Int(header[header.index(header.startIndex, offsetBy: 5)])
                let payload = try transport.receiveExact(payloadLength)
                try tun.send(header + payload)
            } catch let error as IdeviceError where error.raw == IDEVICE_E_TIMEOUT {
                continue
            } catch {
                return
            }
        }
    }

    /// The TUN device already hands back one complete packet per read, so no reframing is needed
    /// on this side -- mirrors go-ios's `forwardTUNToDevice`.
    private func forwardTUNToDevice(mtu: Int) {
        while !shouldStop() {
            do {
                guard let packet = try tun.receive(maxLength: mtu, pollTimeoutMs: 200) else { continue }
                try transport.sendSerialized(packet)
            } catch {
                return
            }
        }
    }
}

