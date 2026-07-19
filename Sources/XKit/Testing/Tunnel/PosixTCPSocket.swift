//
//  PosixTCPSocket.swift
//  XKit
//
//  A raw IPv6 TCP `ByteStream`, used to reach services (RSD, then
//  `com.apple.dt.testmanagerd.remote`) over the TUN interface `CoreDeviceProxyTunnel` sets up --
//  once the tunnel's /64 is routed through the TUN device, connecting to an address inside it is
//  a plain kernel-routed TCP connection like any other, no lockdown/usbmux involvement.
//

import Foundation
#if canImport(Glibc)
import Glibc
#endif

enum PosixTCPSocketError: Swift.Error, Equatable {
    case invalidAddress(String)
    case socketCreateFailed(errno: Int32)
    case connectFailed(errno: Int32)
    case ioFailed(errno: Int32)
    case closed
    case timeout
}

public final class PosixTCPSocket: ByteStream, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var isClosed = false

    public init(address: String, port: Int) throws {
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = UInt16(port).bigEndian
        let parsed = address.withCString { inet_pton(AF_INET6, $0, &addr.sin6_addr) }
        guard parsed == 1 else { throw PosixTCPSocketError.invalidAddress(address) }

        let sock = socket(AF_INET6, Int32(SOCK_STREAM.rawValue), 0)
        guard sock >= 0 else { throw PosixTCPSocketError.socketCreateFailed(errno: errno) }

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(sock, __CONST_SOCKADDR_ARG(__sockaddr__: sockPtr), socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard connectResult == 0 else {
            let savedErrno = errno
            Glibc.close(sock)
            throw PosixTCPSocketError.connectFailed(errno: savedErrno)
        }
        self.fd = sock
    }

    public func send(_ data: Data) throws {
        try checkNotClosed()
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress, raw.count)
            }
            guard written > 0 else { throw PosixTCPSocketError.ioFailed(errno: errno) }
            remaining.removeFirst(written)
        }
    }

    public func receive(maxLength: Int) throws -> Data {
        try checkNotClosed()
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let count = buffer.withUnsafeMutableBytes { raw in
            read(fd, raw.baseAddress, raw.count)
        }
        guard count >= 0 else { throw PosixTCPSocketError.ioFailed(errno: errno) }
        return Data(buffer[0..<count])
    }

    /// Bounded-wait counterpart to `receive(maxLength:)`, for callers (like `DTXConnection`'s read
    /// loop, via `DTXByteTransport`) that need to periodically recheck a stop condition rather
    /// than block indefinitely. Throws `PosixTCPSocketError.timeout` if nothing arrives in time.
    public func receive(maxLength: Int, timeoutMs: Int32) throws -> Data {
        try checkNotClosed()
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, timeoutMs)
        guard ready >= 0 || errno == EINTR else { throw PosixTCPSocketError.ioFailed(errno: errno) }
        guard ready > 0 else { throw PosixTCPSocketError.timeout }
        return try receive(maxLength: maxLength)
    }

    private func checkNotClosed() throws {
        try lock.withLock {
            guard !isClosed else { throw PosixTCPSocketError.closed }
        }
    }

    func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            Glibc.close(fd)
        }
    }

    deinit {
        close()
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
