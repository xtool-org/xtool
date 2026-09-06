//
//  AutoDDIMounter.swift
//  XKit
//
//  Ties `DDIMounter`/`PersonalizedDDIMounter` (which know how to mount a DDI given its content)
//  together with `DeveloperDiskImageRepository` (which knows how to fetch that content) into a
//  single "make sure a DDI is mounted, downloading one if needed" entry point, distinct from
//  `xtool sdk mount-ddi` (a manual, Xcode-source-requiring command) -- without this, every command
//  that needs a DDI-gated service (testmanagerd, instruments, ...) would silently depend on some
//  *other* tool having already mounted one this boot.
//

import Foundation

public enum AutoDDIMounter {
    /// No-op if a Developer/Personalized image is already mounted. Dispatches to the classic
    /// (pre-iOS 17) or personalized (17+) mounter based on `productVersion`, fetching the image
    /// content from `DeveloperDiskImageRepository` if it isn't already cached locally.
    public static func ensureMounted(
        connection: Connection,
        productVersion: String,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let majorVersion = Int(productVersion.split(separator: ".").first ?? "0") ?? 0

        if majorVersion >= 17 {
            #if os(Linux)
            try await ensureMountedPersonalized(connection: connection, onProgress: onProgress)
            #else
            throw Error("Automatic personalized-DDI mounting is only implemented on Linux; use 'xtool sdk mount-ddi' instead.")
            #endif
        } else {
            let mounter = try await DDIMounter(connection: connection)
            guard try !mounter.isMounted() else { return }
            let version = productVersion.split(separator: ".").prefix(2).joined(separator: ".")
            let cacheDir = try DeveloperDiskImageRepository.cacheDirectory()
                .appendingPathComponent("DeveloperDiskImages/\(version)", isDirectory: true)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try await mounter.mountIfNeeded(
                local: .init(
                    dmg: cacheDir.appendingPathComponent("DeveloperDiskImage.dmg"),
                    signature: cacheDir.appendingPathComponent("DeveloperDiskImage.dmg.signature")
                ),
                fetchRemote: {
                    let urls = try DeveloperDiskImageRepository.classicImageURLs(version: version)
                    return .init(dmg: urls.dmg, signature: urls.signature)
                },
                progress: onProgress
            )
        }
    }

    #if os(Linux)
    private static func ensureMountedPersonalized(
        connection: Connection,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let ecid = try await connection.client.value(ofType: UInt64.self, forDomain: nil, key: "UniqueChipID")
        let mounter = try await PersonalizedDDIMounter(connection: connection, ecid: ecid)
        guard try !mounter.isMounted() else { return }
        let resources = try await DeveloperDiskImageRepository.fetchPersonalized(onProgress: onProgress)
        try await mounter.mount(resources: .init(
            image: resources.image,
            buildManifest: resources.buildManifest,
            trustCache: resources.trustCache
        ))
    }
    #endif

    struct Error: Swift.Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
