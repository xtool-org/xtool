//
//  TUNDevice.swift
//  XKit
//
//  Wraps the `xtl_tun_*` ioctl shim (`CXKit/tun_ioctl.c`) into a Swift `ByteStream`: creates a
//  kernel TUN interface, assigns it the IPv6 address the device handed back in the CDTunnel
//  handshake (`CoreDeviceProxyTunnel.swift`), and brings it up. Requires `CAP_NET_ADMIN` (granted
//  to the built `xtool` binary via `setcap`, per the project's tunnel setup notes) -- there is no
//  userspace-network-stack fallback (go-ios falls back to a gVisor-based userspace stack; no
//  Swift equivalent exists, so this project requires the real kernel TUN device).
//
//  Reading/writing the fd directly gives raw IPv6 packets (no framing) since the interface was
//  created with `IFF_NO_PI`.
//

import Foundation
import CXKit
#if canImport(Glibc)
import Glibc
#endif

enum TUNDeviceError: Swift.Error {
    case openFailed(errno: Int32)
    case configureFailed(stage: Int32, errno: Int32)
    case invalidAddress(String)
    case ioFailed(errno: Int32)
    case closed
}

final class TUNDevice: ByteStream, @unchecked Sendable {
    let name: String
    private let fd: Int32
    /// Serializes every `send`/`receive`/`close` on this device's fd. Originally `send`/`receive`
    /// only took a lock around the `isClosed` *check*, not the actual syscall, to let a blocking
    /// `receive` and a concurrent `send` interleave freely -- but that left a real close-during-
    /// syscall race (confirmed via a real SIGSEGV during real-device testing: `close()` closing
    /// the fd out from under a `read(2)`/`write(2)` already in flight on another thread, the same
    /// class of bug `DTXConnection.close()`'s doc comment describes for its own transport).
    /// Routing `close()` through this same queue means it can only run between syscalls, never
    /// during one. The cost -- `send` occasionally waiting behind a `receive`'s bounded poll --
    /// is minor (`receive(maxLength:pollTimeoutMs:)`'s poll is capped at 200ms) and worth the
    /// safety.
    private let ioQueue = DispatchQueue(label: "xtool.tun.io")
    private var isClosed = false

    /// Creates a TUN interface and configures it with `address`/`prefixLength`/`mtu`, matching
    /// go-ios's Linux `setupTunnelInterface` (netlink-based there; ioctl-based here -- both
    /// reach the same kernel state, see `tun_ioctl.c`'s doc comment for why ioctls were chosen).
    /// `mtu` must match the tunnel peer's negotiated MTU (from the CDTunnel handshake) -- a
    /// freshly created TUN device otherwise defaults to 1500, which can silently truncate packets
    /// read into a buffer sized to the (smaller) negotiated MTU; see `tun_ioctl.h`'s doc comment.
    init(address: String, prefixLength: UInt32, mtu: UInt32) throws {
        var nameBuf = [CChar](repeating: 0, count: 16)
        let fd = xtl_tun_create(&nameBuf)
        guard fd >= 0 else { throw TUNDeviceError.openFailed(errno: errno) }
        self.fd = fd
        self.name = nameBuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }

        guard let addr6 = Self.parseIPv6(address) else {
            Glibc.close(fd)
            throw TUNDeviceError.invalidAddress(address)
        }

        var stage: Int32 = -1
        let result = nameBuf.withUnsafeBufferPointer { namePtr -> Int32 in
            addr6.withUnsafeBufferPointer { addrPtr in
                xtl_tun_configure(namePtr.baseAddress!, addrPtr.baseAddress!, prefixLength, mtu, &stage)
            }
        }
        guard result == 0 else {
            let savedErrno = errno
            Glibc.close(fd)
            throw TUNDeviceError.configureFailed(stage: stage, errno: savedErrno)
        }
    }

    private static func parseIPv6(_ string: String) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: 16)
        let result = string.withCString { cstr in
            buf.withUnsafeMutableBytes { rawBuf in
                inet_pton(AF_INET6, cstr, rawBuf.baseAddress)
            }
        }
        return result == 1 ? buf : nil
    }

    func send(_ data: Data) throws {
        try ioQueue.sync {
            guard !isClosed else { throw TUNDeviceError.closed }
            let written = data.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress, raw.count)
            }
            guard written == data.count else { throw TUNDeviceError.ioFailed(errno: errno) }
        }
    }

    /// Blocking read of a single packet (or up to `maxLength` bytes of one, for a caller-owned
    /// buffer sized to the negotiated MTU -- `Read`/`ReadWriteCloser` on a TUN fd always returns
    /// exactly one packet per call, never a partial one or multiple coalesced together, so no
    /// extra framing is needed here unlike the lockdown-connection side of the tunnel).
    func receive(maxLength: Int) throws -> Data {
        try ioQueue.sync {
            guard !isClosed else { throw TUNDeviceError.closed }
            var buffer = [UInt8](repeating: 0, count: maxLength)
            let count = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            guard count >= 0 else { throw TUNDeviceError.ioFailed(errno: errno) }
            return Data(buffer[0..<count])
        }
    }

    /// Like `receive(maxLength:)`, but returns `nil` instead of blocking indefinitely if no
    /// packet arrives within `pollTimeoutMs` -- used by the pump loop in
    /// `CoreDeviceProxyTunnel` so it can periodically check whether it's been asked to stop,
    /// mirroring `DTXConnection`'s `readPollTimeout` convention for the same reason (a plain
    /// blocking `read()` on a TUN fd is not reliably interrupted by another thread closing it).
    /// The `poll()` itself runs inside `ioQueue` too (not just the follow-up `receive`) so
    /// `close()` can't sneak the fd out from under it either.
    func receive(maxLength: Int, pollTimeoutMs: Int32) throws -> Data? {
        let ready = try ioQueue.sync { () -> Bool in
            guard !isClosed else { throw TUNDeviceError.closed }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&pfd, 1, pollTimeoutMs)
            guard result >= 0 || errno == EINTR else { throw TUNDeviceError.ioFailed(errno: errno) }
            return result > 0
        }
        guard ready else { return nil }
        return try receive(maxLength: maxLength)
    }

    func close() {
        ioQueue.sync {
            guard !isClosed else { return }
            isClosed = true
            Glibc.close(fd)
        }
    }

    deinit {
        close()
    }
}
