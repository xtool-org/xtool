//
//  SyslogRelayClient.swift
//  XKit
//
//  Wraps `libimobiledevice/syslog_relay.h` directly, same rationale as `ScreenshotClient`'s
//  header comment. `syslog_relay_start_capture_raw` spawns its own internal worker thread inside
//  libimobiledevice (confirmed by reading `syslog_relay.c`'s `syslog_relay_start_capture`, which
//  calls `thread_new` and returns immediately) and delivers data one byte at a time via a C
//  callback -- there is no dedicated `Thread`/blocking loop needed on the Swift side the way
//  `DTXConnection` needs one for *its* genuinely-blocking C calls.

import Foundation
import SwiftyMobileDevice
import libimobiledevice

public final class SyslogRelayClient: Sendable {
    public struct Error: Swift.Error, LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    private nonisolated(unsafe) let raw: syslog_relay_client_t
    private let box = LineBox()

    public init(device: Device, label: String) throws {
        var client: syslog_relay_client_t?
        let status = syslog_relay_client_start_service(device.raw, &client, label)
        guard status == SYSLOG_RELAY_E_SUCCESS, let client else {
            throw Error("Could not start the syslog_relay service (status \(status.rawValue))")
        }
        self.raw = client
    }

    deinit {
        syslog_relay_stop_capture(raw)
        syslog_relay_client_free(raw)
    }

    /// Yields complete lines as they arrive. The stream finishes once `stop()` is called (which
    /// ends the underlying capture, causing libimobiledevice's worker thread to stop invoking the
    /// callback) or the client is deallocated.
    public func lines() -> AsyncStream<String> {
        AsyncStream { continuation in
            box.continuation = continuation
            let opaque = Unmanaged.passUnretained(box).toOpaque()
            let status = syslog_relay_start_capture_raw(raw, { char, userData in
                guard let userData else { return }
                Unmanaged<LineBox>.fromOpaque(userData).takeUnretainedValue().append(char)
            }, opaque)
            if status != SYSLOG_RELAY_E_SUCCESS {
                continuation.finish()
            }
        }
    }

    public func stop() {
        syslog_relay_stop_capture(raw)
        box.finish()
    }
}

/// Accumulates bytes delivered one at a time (by libimobiledevice's own worker thread, not one we
/// control) into complete lines, forwarding each to an `AsyncStream.Continuation`. A plain class
/// (not an actor) since the C callback is synchronous and can't `await` a hop onto one -- the lock
/// is what makes `buffer` safe to mutate from that background thread.
private final class LineBox: @unchecked Sendable {
    var continuation: AsyncStream<String>.Continuation?
    private var buffer = ""
    private let lock = NSLock()

    func append(_ char: CChar) {
        let scalar = Character(UnicodeScalar(UInt8(bitPattern: char)))
        lock.lock()
        if scalar == "\n" {
            let line = buffer
            buffer = ""
            lock.unlock()
            continuation?.yield(line)
        } else {
            buffer.append(scalar)
            lock.unlock()
        }
    }

    func finish() {
        continuation?.finish()
    }
}
