//
//  ScreenshotClient.swift
//  XKit
//
//  Wraps `libimobiledevice/screenshotr.h` directly -- there's no typed `SwiftyMobileDevice`
//  client for this service (same situation `TestManagerdSession`'s header comment documents for
//  DTX services), so this talks to the C API the same way `PersonalizedDDIMounter` does for
//  `mobile_image_mounter.h`: via the raw `idevice_t` handle `Device` already exposes publicly
//  (`connection.device.raw`), not by patching the vendored `SwiftyMobileDevice` package.

import Foundation
import SwiftyMobileDevice
import libimobiledevice

public final class ScreenshotClient: Sendable {
    public struct Error: Swift.Error, LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    private nonisolated(unsafe) let raw: screenshotr_client_t

    public init(connection: Connection) throws {
        var client: screenshotr_client_t?
        let status = screenshotr_client_start_service(connection.device.raw, &client, "xtool-test-screenshot")
        guard status == SCREENSHOTR_E_SUCCESS, let client else {
            throw Error("Could not start the screenshotr service (status \(status.rawValue))")
        }
        self.raw = client
    }

    deinit { screenshotr_client_free(raw) }

    public func takeScreenshot() throws -> Data {
        var buffer: UnsafeMutablePointer<CChar>?
        var size: UInt64 = 0
        let status = screenshotr_take_screenshot(raw, &buffer, &size)
        guard status == SCREENSHOTR_E_SUCCESS, let buffer else {
            throw Error("Failed to capture a screenshot (status \(status.rawValue))")
        }
        defer { free(buffer) }
        return Data(bytes: buffer, count: Int(size))
    }
}
