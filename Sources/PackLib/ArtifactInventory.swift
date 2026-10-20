import Crypto
import Foundation
import XUtils

/// Portable, exact-byte inventory. This detects mutation; it is not a signature or attestation.
public struct ArtifactInventory: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var files: [String: Entry]

    public struct Entry: Codable, Sendable, Equatable {
        public var kind: String
        public var sha256: String?
        public var executable: Bool
        public var link: String?
    }

    /// A link is safe when it is relative and resolves to an existing item inside `root`.
    /// Both sides resolve symlinks, so a symlinked parent of `root` cannot fail the comparison.
    static func isContainedSymlink(_ url: URL, destination link: String, root: URL) -> Bool {
        let root = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return !link.hasPrefix("/") && resolved.hasPrefix(root + "/") && FileManager.default.fileExists(atPath: resolved)
    }

    public init(directory: URL, hashContents: Bool = true) throws {
        let manager = FileManager.default
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        var pending = try manager.contentsOfDirectory(atPath: root.path)
        var entries: [String: Entry] = [:]
        while let path = pending.popLast() {
            let url = root.appendingPathComponent(path)
            try ResourceDestination.validateRelativePath(path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let link = try manager.destinationOfSymbolicLink(atPath: url.path)
                guard Self.isContainedSymlink(url, destination: link, root: root) else {
                    throw StringError("Broken or escaping artifact symlink: \(path)")
                }
                entries[path] = Entry(kind: "symlink", executable: false, link: link)
            } else if values.isDirectory == true {
                entries[path] = Entry(kind: "directory", executable: false)
                pending += try manager.contentsOfDirectory(atPath: url.path).map { path + "/" + $0 }
            } else if values.isRegularFile == true {
                let attributes = try manager.attributesOfItem(atPath: url.path)
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                entries[path] = Entry(kind: "file", sha256: hashContents ? try Self.hash(url) : nil,
                                      executable: permissions & 0o111 != 0)
            } else {
                throw StringError("Unsupported artifact entry: \(path)")
            }
        }
        guard !entries.isEmpty else { throw StringError("Artifact is empty: \(directory.path)") }
        files = entries
    }

    public func verify(directory: URL) throws {
        guard version == 1 else { throw StringError("Unsupported artifact inventory version: \(version)") }
        let actual = try Self(directory: directory)
        let differences = Set(files.keys).union(actual.files.keys).filter { files[$0] != actual.files[$0] }.sorted()
        guard differences.isEmpty else {
            throw StringError("Artifact inventory mismatch: \(differences.joined(separator: ", "))")
        }
    }

    public static func hash(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
