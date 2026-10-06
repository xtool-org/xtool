import Foundation
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

    public init(
        project: XCSchema.Project,
        format: Format = .pbxproj,
    ) {
        self.project = project
        self.format = format
    }

    /// Reads the project from the given `.xcodeproj` path.
    public init(url: URL) throws {
        guard url.pathExtension == "xcodeproj" else {
            throw Errors.notAnXcodeproj(url.path)
        }
        let xcprojURL = url.appending(path: "project.xcproj")
        lazy var pbxprojURL = url.appending(path: "project.pbxproj")
        if FileManager.default.fileExists(atPath: xcprojURL.path) {
            let data = try Data(contentsOf: xcprojURL)
            self.project = try XCSchema.Project(jsonRepresentation: data)
            self.format = .xcproj
        } else if FileManager.default.fileExists(atPath: pbxprojURL.path) {
            let data = try Data(contentsOf: pbxprojURL)
            self.project = try XCSchema.Project(pbxprojRepresentation: data)
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

    /// Writes the project to the given `.xcodeproj` path.
    public func write(to url: URL) throws {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        switch format {
        case .pbxproj:
            try project
                .pbxprojRepresentation(name: url.deletingPathExtension().lastPathComponent)
                .write(to: url.appendingPathComponent("project.pbxproj"))
        case .xcproj:
            try project
                .jsonRepresentation()
                .write(to: url.appendingPathComponent("project.xcproj"))
        }

        try XcodeWorkspace(children: [.file(.current)])
            .write(to: url.appendingPathComponent("project.xcworkspace"))
    }

    public enum Errors: Error {
        case notAnXcodeproj(String)
        case missingProjectFile(String)
    }
}
