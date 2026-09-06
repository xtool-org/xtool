//
//  CrashLogClient.swift
//  XKit
//
//  Wraps `com.apple.crashreportmover`/`com.apple.crashreportcopymobile` directly, same rationale
//  as `ScreenshotClient`/`SyslogRelayClient`'s header comments -- neither is a typed
//  `SwiftyMobileDevice` client. Protocol transcribed (not copied -- clean-room, matching the rest
//  of this directory) from `libimobiledevice`'s own `idevicecrashreport.c` tool (LGPL-2.1,
//  read for the two-service handshake shape only):
//
//    1. Start `com.apple.crashreportmover` and read up to 10 times (2s timeout each) for a
//       4-byte "ping" -- this tells the device to relocate crash logs from wherever they're
//       staged into the location the second service can actually read.
//    2. Start `com.apple.crashreportcopymobile`, which -- unlike the two services above -- speaks
//       plain AFC, so it's usable through `SwiftyMobileDevice`'s existing `AFCClient` once
//       constructed from the right raw `afc_client_t` (the same way `house_arrest` vends a
//       differently-scoped AFC jail elsewhere in this codebase).

import Foundation
import SwiftyMobileDevice
import libimobiledevice

public struct CrashLogClient: Sendable {
    public struct Error: Swift.Error, LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    private enum ServiceName {
        static let mover = "com.apple.crashreportmover"
        static let copyMobile = "com.apple.crashreportcopymobile"
    }

    private let afc: AFCClient

    public init(connection: Connection) throws {
        try Self.waitForMover(connection: connection)

        var descriptor: lockdownd_service_descriptor_t?
        let status = lockdownd_start_service(connection.client.raw, ServiceName.copyMobile, &descriptor)
        guard status == LOCKDOWN_E_SUCCESS, let descriptor else {
            throw Error("Could not start \(ServiceName.copyMobile) (status \(status.rawValue))")
        }
        defer { lockdownd_service_descriptor_free(descriptor) }

        var afcRaw: afc_client_t?
        let afcStatus = afc_client_new(connection.device.raw, descriptor, &afcRaw)
        guard afcStatus == AFC_E_SUCCESS, let afcRaw else {
            throw Error("Could not open AFC over \(ServiceName.copyMobile) (status \(afcStatus.rawValue))")
        }
        self.afc = AFCClient(raw: afcRaw)
    }

    /// Best-effort, matching `idevicecrashreport.c`: proceeds to open the copy-mobile service
    /// regardless of whether a "ping" was actually observed within 10 attempts, rather than
    /// hard-failing -- the copy service works even without mover confirmation, just possibly
    /// missing very recently written logs.
    private static func waitForMover(connection: Connection) throws {
        var descriptor: lockdownd_service_descriptor_t?
        let status = lockdownd_start_service(connection.client.raw, ServiceName.mover, &descriptor)
        guard status == LOCKDOWN_E_SUCCESS, let descriptor else {
            throw Error("Could not start \(ServiceName.mover) (status \(status.rawValue))")
        }
        defer { lockdownd_service_descriptor_free(descriptor) }

        var client: service_client_t?
        let clientStatus = service_client_new(connection.device.raw, descriptor, &client)
        guard clientStatus == SERVICE_E_SUCCESS, let client else {
            throw Error("Could not open \(ServiceName.mover) connection (status \(clientStatus.rawValue))")
        }
        defer { service_client_free(client) }

        let pingBytes = Data("ping".utf8)
        for _ in 0..<10 {
            var buffer = [UInt8](repeating: 0, count: 4)
            var received: UInt32 = 0
            let recvStatus = buffer.withUnsafeMutableBytes { ptr in
                service_receive_with_timeout(client, ptr.bindMemory(to: CChar.self).baseAddress, 4, &received, 2000)
            }
            guard recvStatus == SERVICE_E_SUCCESS || recvStatus == SERVICE_E_TIMEOUT else {
                throw Error("Crash log mover connection interrupted (status \(recvStatus.rawValue))")
            }
            if recvStatus == SERVICE_E_SUCCESS, received == 4, Data(buffer) == pingBytes {
                return
            }
        }
    }

    /// Filenames directly under the crash-log-copy service's root -- already scoped to just crash
    /// logs (this service doesn't expose the rest of the filesystem), so no path filtering needed.
    public func listCrashReports() throws -> [String] {
        try afc.contentsOfDirectory(at: URL(fileURLWithPath: "/"))
    }

    /// AFC's standard file-info dictionary (`st_mtime`, `st_size`, etc.) for one crash log.
    public func fileInfo(for name: String) throws -> [String: String] {
        try afc.fileInfo(for: URL(fileURLWithPath: "/\(name)"))
    }

    public func readCrashReport(_ name: String) throws -> Data {
        let file = try afc.open(URL(fileURLWithPath: "/\(name)"), mode: .readOnly)
        var data = Data()
        while true {
            let chunk = try file.read(maxLength: 1 << 16)
            if chunk.isEmpty { break }
            data += chunk
        }
        return data
    }
}
