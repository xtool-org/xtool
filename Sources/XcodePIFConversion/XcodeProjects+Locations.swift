import Foundation
import XcodeProjects

extension XcodeProject {
    /// Resolves a literal file reference. SDK, build-product, and unevaluated macro paths return nil.
    func resolve(_ path: XCSchema.FilePath, relativeTo group: URL?) -> URL? {
        let sourceRoot = self.sourceRoot
        let base: URL?
        switch path.base {
        case .absolute: base = nil
        case .group: base = group
        case .project: base = sourceRoot
        case .sourceRoot(let setting):
            switch setting {
            case "SOURCE_ROOT", "SRCROOT", "PROJECT_DIR": base = sourceRoot
            default:
                if case .string(let value) = project.buildSettings[setting], (value as NSString).isAbsolutePath {
                    base = URL(filePath: value)
                } else {
                    return nil
                }
            }
        case .developer, .buildProducts, .sdk: return nil
        }
        var value = (path.path as NSString).expandingTildeInPath
        for name in ["SOURCE_ROOT", "SRCROOT", "PROJECT_DIR"] {
            value = value.replacingOccurrences(of: "$(\(name))", with: sourceRoot.path)
                .replacingOccurrences(of: "${\(name)}", with: sourceRoot.path)
        }
        guard !value.contains("$("), !value.contains("${") else { return nil }
        if (value as NSString).isAbsolutePath { return URL(filePath: value).standardizedFileURL }
        return base?.appending(path: value).standardizedFileURL
    }
}

extension XcodeWorkspace {
    /// Projects explicitly listed in the workspace, in document order. Groups affect paths,
    /// while container-relative locations always start beside the workspace bundle.
    func projectURLs() throws -> [URL] {
        let container = url.deletingLastPathComponent()
        return try projectURLs(in: children, container: container, group: container)
    }

    private func projectURLs(in elements: [Element], container: URL, group: URL) throws -> [URL] {
        try elements.flatMap { element in
            let location = element.location
            let resolved: URL
            switch location.base {
            case .absolute: resolved = URL(filePath: (location.path as NSString).expandingTildeInPath)
            case .container, .current: resolved = container.appending(path: location.path)
            case .group: resolved = group.appending(path: location.path)
            default: throw Errors.unsupportedLocation(location.description)
            }
            switch element {
            case .file:
                return resolved.pathExtension == "xcodeproj" ? [resolved.standardizedFileURL.resolvingSymlinksInPath()] : []
            case .group(let child):
                return try projectURLs(in: child.children, container: container, group: resolved)
            case .fileSystemSynchronizedGroup:
                throw Errors.unsupportedLocation("Synchronized workspace group: \(location)")
            }
        }
    }

    enum Errors: Error {
        case unsupportedLocation(String)
    }
}
