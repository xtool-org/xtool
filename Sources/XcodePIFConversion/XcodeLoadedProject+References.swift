import Foundation
import XcodeProjects
import XPIF

extension XcodeLoadedProject.Loader {
    mutating func convertReferences(
        _ items: [XCSchema.Reference], parentID: XPIF.GUID, names: [String], directory: URL?
    ) throws -> [XPIF.Reference] {
        try items.enumerated().map { index, item in
            let fallback = "\(parentID.value)::REF:\(index)"
            let ref: XPIF.Reference
            let name: String
            let url: URL?
            switch item {
            case .fileReference(let file):
                url = xcodeProject.resolve(file.path, relativeTo: directory)
                let id = try identifier(file.objectID, fallback: fallback)
                let fileRef = try Self.fileReference(file, id: id)
                ref = .file(fileRef)
                name = fileRef.name
                memberships += file.buildFiles.map { (id, $0) }
            case .group(let group):
                url = xcodeProject.resolve(group.path, relativeTo: directory)
                let id = try identifier(group.objectID, fallback: fallback)
                name = group.name
                ref = .group(.init(
                    id: id, path: group.path.path, pathBase: Self.pathBase(group.path.base), name: name,
                    subitems: try convertReferences(group.children, parentID: id, names: names + [name], directory: url)
                ))
            case .variantGroup(let group):
                url = xcodeProject.resolve(group.path, relativeTo: directory)
                let id = try identifier(group.objectID, fallback: fallback)
                name = group.name
                var children = try convertReferences(group.children.map(XCSchema.Reference.fileReference),
                                                     parentID: id, names: names + [name], directory: url)
                for index in children.indices {
                    if case .file(var file) = children[index] {
                        let components = file.path.components(separatedBy: "/")
                        file.regionVariantName = components.first(where: { $0.hasSuffix(".lproj") })
                            .map { String($0.dropLast(".lproj".count)) }
                        children[index] = .file(file)
                        if let entryIndex = references.firstIndex(where: { $0.reference.id == file.id }) {
                            let entry = references[entryIndex]
                            references[entryIndex] = .init(names: entry.names, reference: .file(file), url: entry.url)
                        }
                    }
                }
                var converted = XPIF.Group(
                    id: id,
                    path: group.path.path,
                    pathBase: Self.pathBase(group.path.base),
                    name: name,
                    subitems: children,
                )
                converted.kind = .variantGroup
                ref = .group(converted)
                memberships += group.buildFiles.map { (id, $0) }
            case .versionGroup(let group):
                url = xcodeProject.resolve(group.path, relativeTo: directory)
                let id = try identifier(group.objectID, fallback: fallback)
                name = group.name
                var converted = XPIF.Group(
                    id: id,
                    path: group.path.path,
                    pathBase: Self.pathBase(group.path.base),
                    name: name,
                    subitems: try convertReferences(
                        group.children.map(XCSchema.Reference.fileReference),
                        parentID: id,
                        names: names + [name],
                        directory: url,
                    )
                )
                converted.kind = .versionGroup
                ref = .group(converted)
                memberships += group.buildFiles.map { (id, $0) }
            case .folder(let folder):
                guard let directory = xcodeProject.resolve(folder.path, relativeTo: directory) else {
                    throw ConversionError("Cannot resolve synchronized folder: \(folder.path.path)")
                }
                url = directory
                let id = try identifier(folder.objectID, fallback: fallback)
                name = (folder.path.path as NSString).lastPathComponent
                let contents = try XcodeSynchronizedFolder(
                    folder: folder, project: project, identifierPrefix: folder.objectID?.rawValue ?? fallback
                ).references(at: directory)
                ref = .group(.init(
                    id: id, path: folder.path.path, pathBase: Self.pathBase(folder.path.base), name: name,
                    subitems: try convertReferences(contents, parentID: id, names: names + [name], directory: directory)
                ))
            }
            references.append(.init(names: names + [name], reference: ref, url: url))
            return ref
        }
    }

    static func fileReference(_ file: XCSchema.FileReference, id: XPIF.GUID) throws -> XPIF.FileReference {
        var ref = XPIF.FileReference(
            id: id,
            path: file.path.path,
            pathBase: pathBase(file.path.base),
            name: (file.path.path as NSString).lastPathComponent,
            fileType: file.explicitFileType?.rawValue,
        )
        ref.expectedSignature = file.expectedSignature
        ref.fileTextEncoding = try file.textEncoding.map { encoding in
            guard let name = encoding.rawValue.backportedIANAName else {
                throw ConversionError("Unsupported Xcode file text encoding: \(encoding.rawValue.rawValue)")
            }
            return name
        }
        return ref
    }

    static func pathBase(_ base: XCSchema.FilePath.Base) -> XPIF.Reference.RefPathBase {
        switch base {
        case .absolute: .absolute
        case .group: .groupDir
        case .project: .projectDir
        case .developer: .buildSetting("DEVELOPER_DIR")
        case .buildProducts: .buildDir
        case .sdk: .buildSetting("SDKROOT")
        case .sourceRoot(let setting): .buildSetting(setting)
        }
    }
}
