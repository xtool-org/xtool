import Foundation
import ArgumentParser
import Crypto
import Dependencies
import XKit

struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update xtool to the latest release"
    )

    @Flag(help: "Check for a newer version without installing it") var check = false
    @Flag(help: "Reinstall even if xtool is already up to date") var force = false
    @Flag(help: "Include pre-releases when looking for the latest version") var preRelease = false

    func run() async throws {
        print("Checking for updates...")
        let current = XTool.version
        let release = try await GitHubRelease.fetchLatest(includingPreReleases: preRelease)
        let latest = release.version

        print("Current version: \(current)")
        print("Latest version: \(latest)")

        let isNewer = GitHubRelease.isNewer(latest, than: current)
        if !isNewer && !force {
            if GitHubRelease.parse(current) == nil {
                print("This build of xtool is unversioned, so it can't be compared. Use --force to install \(latest).")
            } else {
                print("xtool is already up to date.")
            }
            return
        }
        if check {
            if isNewer { print("An update is available. Run `xtool update` to install it.") }
            return
        }

        let target = try GitHubRelease.installTarget()
        let assetName = try GitHubRelease.assetName()
        guard let asset = release.assets.first(where: { $0.name == assetName }) else {
            throw Console.Error("Release \(release.tagName) has no asset named '\(assetName)'.")
        }

        print("Downloading update...")
        @Dependency(\.httpClient) var httpClient
        let (_, data) = try await httpClient.makeRequest(
            HTTPRequest(url: asset.browserDownloadURL),
            onProgress: { progress in
                guard let progress else { return }
                print("\r\(Int(progress * 100))%", terminator: "")
                fflush(stdout)
            }
        )
        print()

        print("Verifying download...")
        if let digest = asset.digest {
            let prefix = "sha256:"
            guard digest.hasPrefix(prefix) else {
                throw Console.Error("Unsupported checksum format '\(digest)'.")
            }
            let expected = digest.dropFirst(prefix.count).lowercased()
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard expected == actual else {
                throw Console.Error("Checksum mismatch (expected \(expected), got \(actual)). Aborting.")
            }
        } else {
            print("Warning: no checksum is published for this release; skipping integrity check.")
        }

        print("Installing update...")
        try GitHubRelease.install(data, at: target)
        print("\nSuccessfully updated xtool to \(latest)!")
    }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let digest: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case digest
        }
    }

    let tagName: String
    let prerelease: Bool
    let draft: Bool
    let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
        case draft
        case assets
    }

    var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }

    static func fetchLatest(includingPreReleases: Bool) async throws -> GitHubRelease {
        @Dependency(\.httpClient) var httpClient
        var request = HTTPRequest(
            url: URL(string: "https://api.github.com/repos/xtool-org/xtool/releases?per_page=30")!
        )
        request.headerFields[.accept] = "application/vnd.github+json"
        request.headerFields[.userAgent] = "xtool"
        let (_, body) = try await httpClient.makeRequest(request)
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: body)
        // GitHub returns releases newest-first
        guard let release = releases.first(where: { !$0.draft && (includingPreReleases || !$0.prerelease) }) else {
            throw Console.Error("Could not find a release to update to.")
        }
        return release
    }

    /// Parses a dotted numeric version like `1.2.3` (optionally prefixed with `v`).
    static func parse(_ version: String) -> [Int]? {
        let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = parse(candidate), let current = parse(current) else { return false }
        for i in 0..<max(candidate.count, current.count) {
            let lhs = i < candidate.count ? candidate[i] : 0
            let rhs = i < current.count ? current[i] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    static func assetName() throws -> String {
        #if os(Linux) && arch(x86_64)
        return "xtool-x86_64.AppImage"
        #elseif os(Linux) && arch(arm64)
        return "xtool-aarch64.AppImage"
        #else
        throw unsupported()
        #endif
    }

    /// The path of the executable that should be replaced.
    static func installTarget() throws -> URL {
        #if os(Linux)
        guard let path = ProcessInfo.processInfo.environment["APPIMAGE"], !path.isEmpty else {
            throw Console.Error(
                """
                xtool was not run from an AppImage, so it can't update itself. \
                If you installed it with a package manager, update it using that. \
                Otherwise, download the latest release from https://github.com/xtool-org/xtool/releases.
                """
            )
        }
        return URL(fileURLWithPath: path)
        #else
        throw unsupported()
        #endif
    }

    private static func unsupported() -> Console.Error {
        Console.Error(
            """
            Automatic updates aren't supported on this platform. \
            Download the latest release from https://github.com/xtool-org/xtool/releases \
            or update using the package manager you installed xtool with.
            """
        )
    }

    /// Writes `data` next to `target` and atomically swaps it in, so a failure never leaves a broken install.
    static func install(_ data: Data, at target: URL) throws {
        let fm = FileManager.default
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: staging) }
        do {
            try data.write(to: staging)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
            _ = try fm.replaceItemAt(target, withItemAt: staging)
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            throw Console.Error("Permission denied writing to \(target.path).")
        }
    }
}
