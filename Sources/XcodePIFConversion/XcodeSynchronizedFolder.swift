import Foundation
import Crypto
import XcodeProjects
import XPIF

/// Materializes the discovered references before the project loader resolves their memberships.
struct XcodeSynchronizedFolder {
    let folder: XCSchema.Folder
    let project: XCSchema.Project
    let identifierPrefix: String

    func references(at directory: URL) throws -> [XCSchema.Reference] {
        for target in folder.targets {
            guard project.targets.contains(where: { $0.name == target.targetName }) else {
                throw ConversionError("Unknown synchronized folder target: \(target.targetName)")
            }
        }
        for exception in folder.membershipExceptions {
            switch exception {
            case .target(let exception):
                guard project.targets.contains(where: { $0.name == exception.target.targetName }) else {
                    throw ConversionError("Unknown synchronized folder target: \(exception.target.targetName)")
                }
            case .buildPhase(let exception):
                _ = try resolvePhase(exception.buildPhase)
            }
        }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try references(at: directory, relativePath: "", ancestors: [])
    }

    private func references(at directory: URL, relativePath: String, ancestors: Set<URL>) throws -> [XCSchema.Reference] {
        let canonical = URL(filePath: directory.resolvingSymlinksInPath().path, directoryHint: .notDirectory)
        guard !ancestors.contains(canonical) else {
            throw ConversionError("Cyclic synchronized folder symlink: \(directory.path)")
        }
        let ancestors = ancestors.union([canonical])
        var result: [XCSchema.Reference] = []
        var localized: [String: [XCSchema.FileReference]] = [:]
        for url in try contents(of: directory) {
            let name = url.lastPathComponent
            let path = relativePath + name
            var type = fileType(for: path, isDirectory: isDirectory(url))
            // Xcode treats a discovered Swift package as one opaque reference. Its
            // sources belong to the package graph, not the enclosing native target.
            if type == .file, isDirectory(url),
               FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
                type = .wrapper
            }
            if isDirectory(url), !isOpaque(path, type: type) {
                if url.pathExtension == "lproj" {
                    for file in try localizedFiles(at: url, path: path + "/", filePath: name + "/", ancestors: ancestors) {
                        let logicalPath = String(file.path.path.dropFirst(name.count + 1))
                        localized[logicalPath, default: []].append(file)
                    }
                } else {
                    result.append(.group(.init(
                        objectID: objectID(path, kind: "GROUP"), name: name, path: try groupPath(name), includeInIndex: nil,
                        children: try references(at: url, relativePath: path + "/", ancestors: ancestors)
                    )))
                }
            } else if isDirectory(url), type == .wrapperXcdatamodeld {
                let children = try contents(of: url).filter { $0.pathExtension == "xcdatamodel" }.map { child in
                    try file(at: child, path: path + "/" + child.lastPathComponent, filePath: child.lastPathComponent,
                             type: .wrapperXcdatamodel, buildFiles: [])
                }
                result.append(.versionGroup(.init(
                    objectID: objectID(path, kind: "VERSION"), name: name, path: try groupPath(name), currentVersion: nil,
                    versionedFileType: type.fileTypeID, includeInIndex: nil,
                    buildFiles: try buildFiles(for: [.init(value: path)], fileType: type), children: children
                )))
            } else {
                let type = isDirectory(url) && type == .file ? .folder : type
                result.append(.fileReference(try file(
                    at: url, path: path, filePath: name, type: type,
                    buildFiles: buildFiles(for: [.init(value: path)], fileType: type)
                )))
            }
        }
        // Interface-builder strings belong to their storyboard/xib's variant group.
        for key in localized.keys.sorted() where (key as NSString).pathExtension == "strings" {
            let stem = (key as NSString).deletingPathExtension
            if let interface = [stem + ".storyboard", stem + ".xib"].first(where: { localized[$0] != nil }) {
                localized[interface, default: []] += localized.removeValue(forKey: key) ?? []
            }
        }
        for key in localized.keys.sorted() {
            let children = localized[key] ?? []
            let members = children.map { XCSchema.FolderMemberID(value: relativePath + $0.path.path) }
            result.append(.variantGroup(.init(
                objectID: objectID(relativePath + key, kind: "VARIANT"), name: key, path: try groupPath(""),
                includeInIndex: nil, buildFiles: try buildFiles(for: members, fileType: fileType(for: key, isDirectory: false)),
                children: children
            )))
        }
        // Xcode places discovered groups before files, then sorts each category by name like Finder does.
        return result.sorted {
            func key(_ ref: XCSchema.Reference) -> (Int, String) {
                switch ref {
                case .group(let group): return (0, group.name)
                case .variantGroup(let group): return (1, group.name)
                case .versionGroup(let group): return (1, group.name)
                case .fileReference(let file): return (1, file.path.path)
                case .folder(let folder): return (0, folder.path.path)
                }
            }
            let (lhs, rhs) = (key($0), key($1))
            return lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1.localizedStandardCompare(rhs.1) == .orderedAscending
        }
    }

    private func localizedFiles(
        at directory: URL, path: String, filePath: String, ancestors: Set<URL>
    ) throws -> [XCSchema.FileReference] {
        let canonical = URL(filePath: directory.resolvingSymlinksInPath().path, directoryHint: .notDirectory)
        guard !ancestors.contains(canonical) else {
            throw ConversionError("Cyclic synchronized folder symlink: \(directory.path)")
        }
        return try contents(of: directory).flatMap { url in
            let name = url.lastPathComponent
            let type = fileType(for: path + name, isDirectory: isDirectory(url))
            if isDirectory(url), !isOpaque(path + name, type: type) {
                return try localizedFiles(at: url, path: path + name + "/", filePath: filePath + name + "/",
                                          ancestors: ancestors.union([canonical]))
            }
            return [try file(at: url, path: path + name, filePath: filePath + name, type: type, buildFiles: [])]
        }
    }

    private func contents(of directory: URL) throws -> [URL] {
        // Like hidden files, Xcode ignores backup files (`name~`).
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { !$0.lastPathComponent.hasSuffix("~") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private func isOpaque(_ path: String, type: XcodeFileType) -> Bool {
        folder.explicitOpaqueFolders.contains(.init(value: path)) || type != .file
    }

    private func fileType(for path: String, isDirectory: Bool) -> XcodeFileType {
        if let type = folder.explicitFileTypes[.init(value: path)] { return XcodeFileType(type) }
        let name = (path as NSString).lastPathComponent
        let type = isDirectory ? XcodeFileType.forDirectory(named: name) : XcodeFileType.forFile(named: name)
        return type ?? .file
    }

    private func file(
        at url: URL, path: String, filePath: String, type: XcodeFileType, buildFiles: [XCSchema.ProjectBuildFile]
    ) throws -> XCSchema.FileReference {
        .init(objectID: objectID(path, kind: "FILE"), path: try groupPath(filePath), explicitFileType: type.fileTypeID,
              expectedSignature: nil, textEncoding: try textEncoding(at: url, fileType: type),
              lineEnding: nil, includeInIndex: nil, buildFiles: buildFiles)
    }

    private func textEncoding(at url: URL, fileType: XcodeFileType) throws -> XCSchema.TextEncoding? {
        guard fileType.requiresExplicitTextEncoding else { return nil }
        var encoding = String.Encoding.utf8
        _ = try String(contentsOf: url, usedEncoding: &encoding)
        return .init(rawValue: encoding == .ascii ? .utf8 : encoding)
    }

    private func groupPath(_ path: String) throws -> XCSchema.FilePath {
        try .init(base: .group, path: path)
    }

    /// Discovered references use SHA-256(project GUID + root object ID + relative path).
    /// Build files additionally include the owning phase's PBX ID; variant groups add a suffix.
    static func pifGUID(_ objectID: XCSchema.ObjectID, projectPrefix: String) -> XPIF.GUID? {
        let parts = objectID.rawValue.components(separatedBy: "::SYNCHRONIZED:")
        guard parts.count == 2, let separator = parts[1].firstIndex(of: ":") else { return nil }
        let kind = String(parts[1][..<separator])
        var path = String(parts[1][parts[1].index(after: separator)...])
        var input = projectPrefix + parts[0]
        if kind == "BUILD", let separator = path.firstIndex(of: ":") {
            input += path[..<separator]
            path = String(path[path.index(after: separator)...])
        }
        input += path
        if kind == "VARIANT" { input += "VariantGroup" }
        return .init(Data(SHA256.hash(data: Data(input.utf8))).base64EncodedString())
    }

    private func objectID(_ path: String, kind: String) -> XCSchema.ObjectID {
        .init("\(identifierPrefix)::SYNCHRONIZED:\(kind):\(path)")
    }
}
