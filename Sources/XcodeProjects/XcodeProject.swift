import Foundation
private import XcodeProj
@_exported import XcodeProjectFormat

// This library is a lightweight layer on top of the XcodeProjectFormat
// interface, providing other facilities for working with the Xcode
// project formats.
//
// We currently use XcodeProj under the hood for some functionality, but this
// should be considered an implementation detail.

public struct XcodeProject: Equatable, Sendable {
    public enum Format: Sendable {
        case pbxproj
        case xcproj
    }

    public var project: XCSchema.Project
    public var format: Format
    /// The .xcodeproj bundle's location, including for projects constructed in memory.
    public var url: URL
    /// For pbxproj projects, an explicit source root.
    public var projectDirPath = ""

    public var sourceRoot: URL {
        if projectDirPath.isEmpty {
            url.deletingLastPathComponent()
        } else {
            URL(
                filePath: projectDirPath,
                directoryHint: .isDirectory,
                relativeTo: url.deletingLastPathComponent(),
            ).standardizedFileURL
        }
    }

    public init(
        project: XCSchema.Project,
        url: URL,
        format: Format = .pbxproj,
    ) {
        self.project = project
        self.format = format
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Reads the project from the given `.xcodeproj` path.
    public init(url: URL) throws {
        guard url.pathExtension == "xcodeproj" else {
            throw Errors.notAnXcodeproj(url.path)
        }
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.url = url
        let xcprojURL = url.appending(path: "project.xcproj")
        lazy var pbxprojURL = url.appending(path: "project.pbxproj")
        if FileManager.default.fileExists(atPath: xcprojURL.path) {
            let data = try Data(contentsOf: xcprojURL)
            self.project = try XCSchema.Project(jsonRepresentation: data)
            self.format = .xcproj
        } else if FileManager.default.fileExists(atPath: pbxprojURL.path) {
            let data = try Data(contentsOf: pbxprojURL)
            let pbxproj = try PBXProj(data: data)
            self.project = try XCSchema.Project(jsonRepresentation: pbxproj.xcprojData())
            self.projectDirPath = try pbxproj.rootProject()?.projectDirPath ?? ""
            self.format = .pbxproj
        } else {
            throw Errors.missingProjectFile(url.path)
        }
    }

    /// Sets the format in which the project should be serialized.
    public func withFormat(_ format: Format) -> XcodeProject {
        var copy = self
        copy.format = format
        return copy
    }

    /// Returns a copy at a new bundle location.
    public func withURL(_ url: URL) -> Self {
        var copy = self
        copy.url = url.standardizedFileURL.resolvingSymlinksInPath()
        return copy
    }

    /// Writes the project to its current `.xcodeproj` URL.
    public func write() throws {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        switch format {
        case .pbxproj:
            try project.pbxprojRepresentation(
                name: url.deletingPathExtension().lastPathComponent,
                projectDirPath: projectDirPath,
            ).write(to: url.appendingPathComponent("project.pbxproj"))
        case .xcproj:
            guard projectDirPath.isEmpty else {
                throw Errors.xcprojWithExplicitSourceRoot
            }
            try project
                .jsonRepresentation()
                .write(to: url.appendingPathComponent("project.xcproj"))
        }

        let workspaceURL = url.appendingPathComponent("project.xcworkspace")
        try XcodeWorkspace(children: [.file(.current)], url: workspaceURL).write()
    }

    public enum Errors: Error {
        case notAnXcodeproj(String)
        case missingProjectFile(String)
        case xcprojWithExplicitSourceRoot
    }
}
