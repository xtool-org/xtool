//
//  DeveloperDiskImageRepository.swift
//  XKit
//
//  Apple doesn't distribute Developer Disk Images (classic or personalized) outside of Xcode --
//  `PersonalizedDDIMounter`/`DDIMounter` can mount one once they have the actual image bytes, but
//  sourcing those bytes on a machine with no Xcode is a separate problem. This fetches them from
//  `doronz88/DeveloperDiskImage` (MIT-licensed, publicly hosted on GitHub), the same
//  community-maintained mirror pymobiledevice3's own `auto_mount_personalized`/
//  `auto_mount_developer` use for exactly this purpose -- confirmed by reading
//  `developer_disk_image.repo.DeveloperDiskImageRepository` (Apache-2.0-compatible; read for the
//  repository layout/file paths only, not copied).
//

import Foundation
import Dependencies

public enum DeveloperDiskImageRepository {
    private static let rawBaseURL = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main"

    public struct PersonalizedResources: Sendable {
        public let image: Data
        public let buildManifest: Data
        public let trustCache: Data
    }

    struct Error: Swift.Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Fetches (with persistent local disk caching, since these are unpersonalized/device-
    /// independent and only need downloading once ever) the personalized DDI content used on
    /// iOS 17+ from the repository. `onProgress` only tracks the image download (by far the
    /// largest of the three files, ~15MB as of writing).
    public static func fetchPersonalized(
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> PersonalizedResources {
        let dir = try cacheDirectory().appendingPathComponent(
            "PersonalizedImages/Xcode_iOS_DDI_Personalized", isDirectory: true
        )
        let imageURL = dir.appendingPathComponent("Image.dmg")
        let manifestURL = dir.appendingPathComponent("BuildManifest.plist")
        let trustCacheURL = dir.appendingPathComponent("Image.dmg.trustcache")

        if let image = try? Data(contentsOf: imageURL),
           let manifest = try? Data(contentsOf: manifestURL),
           let trustCache = try? Data(contentsOf: trustCacheURL) {
            onProgress(1)
            return PersonalizedResources(image: image, buildManifest: manifest, trustCache: trustCache)
        }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let base = "PersonalizedImages/Xcode_iOS_DDI_Personalized"
        let manifest = try await fetch("\(base)/BuildManifest.plist")
        let trustCache = try await fetch("\(base)/Image.dmg.trustcache")
        let image = try await fetch("\(base)/Image.dmg", onProgress: onProgress)

        try image.write(to: imageURL)
        try manifest.write(to: manifestURL)
        try trustCache.write(to: trustCacheURL)

        return PersonalizedResources(image: image, buildManifest: manifest, trustCache: trustCache)
    }

    /// Remote (not-yet-downloaded) locations for the classic DDI matching `version` ("major.minor",
    /// e.g. "16.7"), for use with `DDIMounter.mountIfNeeded(local:fetchRemote:)`'s `fetchRemote`
    /// parameter -- that function already downloads + locally caches from whatever URLs this
    /// returns, so this doesn't fetch anything itself.
    public static func classicImageURLs(version: String) throws -> (dmg: URL, signature: URL) {
        let base = "DeveloperDiskImages/\(version)/DeveloperDiskImage.dmg"
        guard let dmg = URL(string: "\(rawBaseURL)/\(base)"),
              let signature = URL(string: "\(rawBaseURL)/\(base).signature")
        else {
            throw Error("Could not construct repository URL for DDI version \(version)")
        }
        return (dmg, signature)
    }

    private static func fetch(_ path: String, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Data {
        guard let url = URL(string: "\(rawBaseURL)/\(path)") else {
            throw Error("Invalid repository URL for \(path)")
        }
        @Dependency(\.httpClient) var httpClient
        let (_, data) = try await httpClient.makeRequest(HTTPRequest(url: url)) { progress in
            onProgress(progress ?? 0)
        }
        return data
    }

    static func cacheDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("xtool/DeveloperDiskImageRepository", isDirectory: true)
    }
}
