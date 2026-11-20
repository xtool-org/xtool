import Foundation
import XUtils

/// Extracts Apple Archive entries into a directory.
///
/// Supports regular files, directories, symbolic links and hard links,
/// along with their permissions and modification times. Ownership, flags,
/// extended attributes and ACLs are not restored.
///
/// Entries may not escape the destination, either via `..` components
/// or via symbolic links created by earlier entries.
final class AppleArchiveExtractor {
    private struct PendingDirectory {
        var path: String
        var mode: UInt16
        var modificationDate: Date?
    }

    private struct OpenFile {
        var path: String
        var fd: FileDescriptor
        var header: AppleArchiveHeader
    }

    private enum Current {
        case none
        case skipped
        case file(OpenFile)
    }

    private let fileManager = FileManager.default
    private let destination: String
    private let filter: ((String) -> Bool)?
    private var current = Current.none
    private var knownDirectories: Set<String> = [""]
    private var symlinks: Set<String> = []
    private var hardLinkClusters: [UInt64: String] = [:]
    private var directories: [PendingDirectory] = []

    /// - Parameter filter: Called with each entry's path. Return `false` to skip the entry.
    init(destination: FilePath, filter: ((String) -> Bool)? = nil) throws {
        self.destination = destination.string
        self.filter = filter
        try fileManager.createDirectory(atPath: self.destination, withIntermediateDirectories: true)
    }

    deinit {
        if case .file(let file) = current {
            try? file.fd.close()
        }
    }

    /// Extracts the (unencrypted) Apple Archive at `archive` into `destination`.
    static func extract(archive: FilePath, to destination: FilePath) throws {
        let extractor = try AppleArchiveExtractor(destination: destination)
        let input = try FileDescriptor.open(archive, .readOnly)
        defer { try? input.close() }
        var decoder = AppleArchiveDecoder()
        var buffer = Data(count: 1 << 20)
        while true {
            let count = try buffer.withUnsafeMutableBytes { try input.read(into: $0) }
            if count == 0 { break }
            try decoder.decode(buffer.prefix(count)) { try extractor.handle($0) }
        }
        try decoder.finish()
        try extractor.finish()
    }

    func handle(_ event: AppleArchiveDecoder.Event) throws {
        switch event {
        case .header(let header):
            current = try begin(header)
        case .blob(let key, let data):
            guard key == .data, case .file(let file) = current else { break }
            _ = try file.fd.writeAll(data)
        case .endOfEntry:
            let entry = current
            current = .none
            if case .file(let file) = entry {
                try end(file)
            }
        }
    }

    /// Applies deferred directory metadata. Call this once all entries
    /// have been handled.
    func finish() throws {
        // children before parents, so that read-only directories
        // and modification times are applied last.
        for directory in directories.reversed() {
            try setAttributes(
                path: directory.path,
                mode: directory.mode,
                modificationDate: directory.modificationDate
            )
        }
        directories.removeAll()
    }

    private func absolute(_ path: String) -> String {
        path.isEmpty ? destination : "\(destination)/\(path)"
    }

    private func begin(_ header: AppleArchiveHeader) throws -> Current {
        guard let type = header.entryType, let rawPath = header.path else {
            throw AEAError("Apple Archive entry is missing a type or path")
        }
        if type == .metadata { return .skipped }

        let path = try Self.sanitize(rawPath)
        if let filter, !filter(path) { return .skipped }
        if !path.isEmpty {
            try ensureParent(of: path)
        }

        switch type {
        case .directory:
            try createDirectory(path: path, header: header)
            return .skipped
        case .symbolicLink:
            guard let target = header.linkPath, !path.isEmpty else {
                throw AEAError("Invalid symbolic link entry '\(rawPath)'")
            }
            try createSymlink(path: path, target: target, header: header)
            return .skipped
        case .regularFile:
            guard !path.isEmpty else {
                throw AEAError("Invalid file entry '\(rawPath)'")
            }
            return try createFile(path: path, header: header)
        default:
            throw AEAError(
                "Unsupported Apple Archive entry type '\(UnicodeScalar(type.rawValue))' for '\(rawPath)'"
            )
        }
    }

    private func createDirectory(path: String, header: AppleArchiveHeader) throws {
        if !path.isEmpty {
            // the real mode is applied by finish(), once we're done writing to it
            do {
                try fileManager.createDirectory(atPath: absolute(path), withIntermediateDirectories: false)
            } catch where Self.isFileExists(error) {
                let type = try fileManager.attributesOfItem(atPath: absolute(path))[.type] as? FileAttributeType
                if type != .typeDirectory {
                    try fileManager.removeItem(atPath: absolute(path))
                    symlinks.remove(path)
                    try fileManager.createDirectory(atPath: absolute(path), withIntermediateDirectories: false)
                }
            }
            knownDirectories.insert(path)
        }
        directories.append(PendingDirectory(
            path: path,
            mode: header.mode ?? 0o755,
            modificationDate: header.modificationDate
        ))
    }

    private func createSymlink(path: String, target: String, header: AppleArchiveHeader) throws {
        try replacingExisting(path) {
            try fileManager.createSymbolicLink(atPath: absolute(path), withDestinationPath: target)
        }
        symlinks.insert(path)
        #if canImport(Darwin)
        // only Darwin supports modes on symlinks, and FileManager.setAttributes
        // follows them, so this needs lchmod.
        if let mode = header.mode, lchmod(absolute(path), mode_t(Self.permissions(mode))) != 0 {
            throw Errno(rawValue: errno)
        }
        #endif
    }

    private func createFile(path: String, header: AppleArchiveHeader) throws -> Current {
        // every member of a hard link cluster may carry its own copy of the data;
        // link to the first one we extracted and discard the rest.
        if let cluster = header.hardLinkCluster {
            if let existing = hardLinkClusters[cluster] {
                try replacingExisting(path) {
                    try fileManager.linkItem(atPath: absolute(existing), toPath: absolute(path))
                }
                return .skipped
            }
            hardLinkClusters[cluster] = path
        }
        let fd = try replacingExisting(path) {
            try FileDescriptor.open(
                absolute(path), .writeOnly,
                options: [.create, .exclusiveCreate],
                permissions: .ownerReadWrite
            )
        }
        return .file(OpenFile(path: path, fd: fd, header: header))
    }

    private func end(_ file: OpenFile) throws {
        try file.fd.close()
        try setAttributes(
            path: file.path,
            mode: file.header.mode ?? 0o644,
            modificationDate: file.header.modificationDate
        )
    }

    /// Sets the attributes of the item at `path`, following symlinks.
    private func setAttributes(path: String, mode: UInt16, modificationDate: Date?) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: Int(Self.permissions(mode))]
        attributes[.modificationDate] = modificationDate
        try fileManager.setAttributes(attributes, ofItemAtPath: absolute(path))
    }

    /// Drops setuid/setgid bits.
    private static func permissions(_ mode: UInt16) -> UInt16 {
        mode & 0o1777
    }

    /// Creates the parent directory of `path` if needed, rejecting paths that
    /// traverse symlinks created by earlier entries.
    private func ensureParent(of path: String) throws {
        var prefix = ""
        for component in path.split(separator: "/").dropLast() {
            prefix = prefix.isEmpty ? String(component) : "\(prefix)/\(component)"
            if symlinks.contains(prefix) {
                throw AEAError("Apple Archive entry '\(path)' traverses a symbolic link")
            }
        }
        guard !knownDirectories.contains(prefix) else { return }
        try fileManager.createDirectory(atPath: absolute(prefix), withIntermediateDirectories: true)
        while !prefix.isEmpty, knownDirectories.insert(prefix).inserted {
            prefix = String(prefix[..<(prefix.lastIndex(of: "/") ?? prefix.startIndex)])
        }
    }

    /// Runs `create`. If that fails because a non-directory already exists at
    /// `path` (relative to the destination), removes it and tries again.
    @discardableResult
    private func replacingExisting<T>(_ path: String, _ create: () throws -> T) throws -> T {
        do {
            return try create()
        } catch where Self.isFileExists(error) {
            let absolutePath = absolute(path)
            if try fileManager.attributesOfItem(atPath: absolutePath)[.type] as? FileAttributeType == .typeDirectory {
                throw AEAError("Cannot replace directory '\(absolutePath)'")
            }
            try fileManager.removeItem(atPath: absolutePath)
            symlinks.remove(path)
            return try create()
        }
    }

    private static func isFileExists(_ error: any Error) -> Bool {
        (error as? CocoaError)?.code == .fileWriteFileExists || (error as? Errno) == .fileExists
    }

    /// Normalizes an entry path, rejecting ones that could escape the destination.
    static func sanitize(_ path: String) throws -> String {
        guard !path.hasPrefix("/") else {
            throw AEAError("Apple Archive entry has an absolute path: '\(path)'")
        }
        let components = path.split(separator: "/").filter { $0 != "." }
        guard !components.contains("..") else {
            throw AEAError("Apple Archive entry escapes the destination: '\(path)'")
        }
        return components.joined(separator: "/")
    }
}
