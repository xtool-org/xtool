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
    /// An explicit PBX projectDirPath override. nil = use the .xcodeproj bundle's parent directory.
    public var sourceRoot: URL?

    public init(
        project: XCSchema.Project,
        url: URL,
        format: Format = .pbxproj,
        sourceRoot: URL? = nil,
    ) {
        self.project = project
        self.format = format
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.sourceRoot = sourceRoot?.standardizedFileURL
    }

    /// Reads the project from the given `.xcodeproj` path.
    public init(url: URL) throws {
        guard url.pathExtension == "xcodeproj" else {
            throw Errors.notAnXcodeproj(url.path)
        }
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.url = url
        self.sourceRoot = nil
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
            let directory = try pbxproj.rootProject()?.projectDirPath ?? ""
            if !directory.isEmpty {
                self.sourceRoot = (directory as NSString).isAbsolutePath
                    ? URL(filePath: directory).standardizedFileURL
                    : url.deletingLastPathComponent().appending(path: directory).standardizedFileURL
            }
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

    /// Returns a copy at a new bundle location, preserving any explicit source root.
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
                projectDirPath: sourceRoot?.path ?? ""
            ).write(to: url.appendingPathComponent("project.pbxproj"))
        case .xcproj:
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
    }
}
