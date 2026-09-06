//
//  DDIMounter.swift
//  XKit
//
//  Created by Kabir Oberai on 25/03/21.
//  Copyright © 2021 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice
import Dependencies

/// Mounts the Developer Disk Image (classic, pre-iOS 17) required to expose
/// developer-only lockdown services such as `com.apple.testmanagerd.lockdown`.
///
/// For iOS 17+ devices, use ``PersonalizedDDIMounter`` instead -- Apple replaced the
/// single shared DDI with a per-device "personalized" image starting iOS 17. Callers
/// should branch on the device's product version; see `DDIMounter.mount(on:...)`.
public final class DDIMounter: Sendable {

    public struct DDILoc: Sendable {
        public let dmg: URL
        public let signature: URL

        public init(dmg: URL, signature: URL) {
            self.dmg = dmg
            self.signature = signature
        }
    }

    enum MounterStatus: String, Decodable {
        case complete = "Complete"
    }

    /// `mobile_image_mounter_lookup_image` returns successfully (an empty-but-valid plist) even
    /// when nothing is mounted, so a bare "did this throw" check always reports "mounted"
    /// regardless of actual state -- callers must decode the response and check `status` instead.
    /// Shared with `PersonalizedDDIMounter.isMounted()`, since the response shape doesn't differ
    /// between classic and personalized image types.
    struct MountedImage: Decodable {
        let status: MounterStatus?
        let signature: [Data]?

        private enum CodingKeys: String, CodingKey {
            case signature = "ImageSignature"
            case status = "Status"
        }
    }

    struct MountResult: Decodable {
        let status: MounterStatus?
        let error: String?

        private enum CodingKeys: String, CodingKey {
            case status = "Status"
            case error = "Error"
        }
    }

    public struct Error: Swift.Error, LocalizedError {
        public let message: String?
        public init(message: String?) { self.message = message }
        public var errorDescription: String? { message ?? "Failed to mount the Developer Disk Image" }
    }

    private let client: MobileImageMounterClient
    public init(connection: Connection) async throws {
        self.client = try await connection.startClient()
    }

    /// Returns `true` if a "Developer" image is already mounted.
    public func isMounted() throws -> Bool {
        let mounted = try client.lookup(imageType: "Developer", resultType: MountedImage.self)
        return mounted.signature?.isEmpty == false
    }

    private func mount(data: Data, signature: Data) throws {
        // InputStream(data:) is a plain memory-backed stream (unlike the CFSocketStream-based
        // Stream.getBoundStreams piping this used to go through), so it works identically on
        // Linux, macOS, and Windows.
        let stream = InputStream(data: data)
        stream.open()
        defer { stream.close() }

        try client.upload(imageType: "Developer", file: stream, size: data.count, signature: signature)
        let result = try client.mount(imageType: "Developer", signature: signature, resultType: MountResult.self)
        guard result.status == .complete else {
            throw Error(message: result.error)
        }
    }

    /// Mounts the classic Developer Disk Image, using `local` as a cache and falling back to
    /// `fetchRemote` (a pair of URLs to download) if it isn't present or is invalid.
    ///
    /// No-op if a Developer image is already mounted.
    public func mountIfNeeded(
        local: DDILoc,
        fetchRemote: @Sendable () async throws -> DDILoc,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard try !isMounted() else { return }

        @Dependency(\.httpClient) var httpClientDependency
        let httpClient = httpClientDependency

        let dmgData: Data
        let signature: Data
        if let cachedDMG = try? Data(contentsOf: local.dmg),
           let cachedSignature = try? Data(contentsOf: local.signature) {
            dmgData = cachedDMG
            signature = cachedSignature
            progress(1)
        } else {
            let remote = try await fetchRemote()

            async let dmgResult = httpClient.makeRequest(HTTPRequest(url: remote.dmg)) { downloadProgress in
                // signature download is comparatively tiny, so weight the dmg download
                // as ~95% of overall progress
                progress((downloadProgress ?? 0) * 0.95)
            }
            let (_, signatureData) = try await httpClient.makeRequest(HTTPRequest(url: remote.signature))
            let (_, dmgFetchedData) = try await dmgResult

            dmgData = dmgFetchedData
            signature = signatureData

            try? FileManager.default.createDirectory(
                at: local.dmg.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? dmgData.write(to: local.dmg)
            try? signature.write(to: local.signature)

            progress(1)
        }

        try mount(data: dmgData, signature: signature)
    }

}
