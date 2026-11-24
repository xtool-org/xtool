import Foundation
import OrderedCollections
import XcodeProjects
import XPIF

/// Converts Xcode projects and workspaces into the workspace consumed by Swift Build.
public struct XcodePIFBuilder: Sendable {
    enum Input: Sendable {
        case project(XcodeProject)
        case workspace(XcodeWorkspace)
    }

    let workspaceURL: URL
    let workspaceName: String
    private(set) var projects: OrderedDictionary<URL, XcodeLoadedProject> = [:]

    public init(project: XcodeProject) throws {
        self.workspaceURL = project.url.appending(path: "project.xcworkspace")
        self.workspaceName = project.url.deletingPathExtension().lastPathComponent
        try add(project)
        try loadReferences()
    }

    public init(workspace: XcodeWorkspace) throws {
        self.workspaceURL = workspace.url
        self.workspaceName = workspace.url.deletingPathExtension().lastPathComponent
        for projectURL in try workspace.projectURLs() {
            try load(projectURL)
        }
        try loadReferences()
    }

    private mutating func load(_ url: URL) throws {
        let url = url.canonicalized
        guard projects[url] == nil else { return }
        try add(XcodeProject(url: url))
    }

    private var identifierBaseURL: URL {
        let parent = workspaceURL.deletingLastPathComponent()
        return parent.pathExtension == "xcodeproj" ? parent.deletingLastPathComponent() : parent
    }

    private mutating func add(_ project: XcodeProject) throws {
        let key = project.url.canonicalized
        guard projects[key] == nil else { return }
        projects[key] = try XcodeLoadedProject(xcodeProject: project, projectURL: key, baseURL: identifierBaseURL)
    }

    private mutating func loadReferences() throws {
        var index = 0
        while index < projects.count {
            let (url, project) = projects.elements[index]
            for reference in project.references {
                guard case .file(let file) = reference.reference, (file.path as NSString).pathExtension == "xcodeproj" else {
                    continue
                }
                guard let projectURL = reference.url else {
                    throw ConversionError("Cannot resolve Xcode project reference: \(file.path) in \(url.path)")
                }
                try load(projectURL)
            }
            index += 1
        }

        guard !projects.isEmpty else { throw ConversionError("Xcode workspace contains no projects.") }
    }

    public struct PackageReference: Sendable {
        public let sourceRoot: URL
        public let package: XCSchema.SwiftPackage
        /// Packages present in the navigator are roots of Xcode's package graph.
        public var isRoot = false
    }

    public var packageReferences: [PackageReference] {
        var result = projects.values.flatMap { project in
            project.project.packages.map { PackageReference(sourceRoot: project.sourceRoot, package: $0) }
        }
        // Local packages can be file references (including synchronized-folder
        // discoveries) without an entry in the project's packageReferences list.
        var localIndices: [String: Int] = [:]
        for (index, reference) in result.enumerated() {
            guard case .local(let package) = reference.package.location else { continue }
            let path = URL(fileURLWithPath: package.path, relativeTo: reference.sourceRoot)
                .standardizedFileURL.resolvingSymlinksInPath().path
            localIndices[path] = index
        }
        for project in projects.values {
            for reference in project.references {
                guard case .file = reference.reference, let url = reference.url,
                      FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) else { continue }
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                if let index = localIndices[path] {
                    result[index].isRoot = true
                    continue
                }
                localIndices[path] = result.count
                result.append(PackageReference(sourceRoot: project.sourceRoot,
                                               package: .init(location: .local(.init(path: url.path)), traits: []), isRoot: true))
            }
        }
        return result
    }

    public var packageWorkspaceURL: URL { workspaceURL }

    public func build(packageProjects: [XPIF.Project] = []) throws -> XPIF.Workspace {
        guard packageReferences.isEmpty || !packageProjects.isEmpty else {
            throw ConversionError("Package references must be resolved before generating Xcode PIF.")
        }
        let converted = try projects.values.sorted { $0.projectURL.path < $1.projectURL.path }.map { project in
            var builder = XcodePIFProjectBuilder(loaded: project, packageProjects: packageProjects)
            return try builder.buildProject(in: projects)
        }
        return XPIF.Workspace(
            id: .init(XcodeLoadedProject.digest(workspaceName)),
            name: workspaceName,
            path: workspaceURL.path,
            projects: converted + packageProjects,
        )
    }
}

extension XcodePIFProjectBuilder {
    func referencedProject(
        _ reference: XCSchema.GroupTreeReference,
        in projects: OrderedDictionary<URL, XcodeLoadedProject>
    ) throws -> XcodeLoadedProject {
        let ref = try loaded.resolve(reference)
        guard case .file(let file) = ref, (file.path as NSString).pathExtension == "xcodeproj",
              let url = loaded.references.first(where: { $0.reference.id == ref.id })?.url,
              let project = projects[url.canonicalized] else {
            throw ConversionError("Missing or unresolved Xcode project reference: \(reference) in \(loaded.projectURL.path)")
        }
        return project
    }
}

extension URL {
    fileprivate var canonicalized: URL {
        // URL equality distinguishes a directory URL's trailing slash. A project loaded
        // from the workspace and from a file reference must share one registry entry.
        URL(filePath: self.standardizedFileURL.resolvingSymlinksInPath().path, directoryHint: .notDirectory)
    }
}
