import XCLIUtils
import XUtils
import Foundation
import Testing
@testable import XToolSupport

struct PackSchemaTests {
    @Test(arguments: ["Package.swift", "App.xcworkspace", "App.xcodeproj"], [false, true])
    func selectsConfiguredProject(name: String, absolute: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appending(path: "Nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let project = nested.appending(path: name)
        if name == "Package.swift" {
            try Data().write(to: project)
        } else {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }
        // Explicit selection takes precedence even when discovery would be ambiguous.
        for name in ["Other.xcworkspace", "Another.xcworkspace"] {
            try FileManager.default.createDirectory(at: directory.appending(path: name), withIntermediateDirectories: true)
        }
        let path = absolute ? project.path : "Nested/\(name)"
        try Data("""
        version: 1
        orgID: org.example
        project: \(path)
        skipLSP: true
        """.utf8).write(to: directory.appending(path: "xtool.yml"))

        let discovered = try await XToolProject.discover(start: directory)
        #expect(discovered.base.schema.project == path)
        #expect(discovered.base.schema.skipLSP == true)
        switch discovered {
        case .swiftPM(let swiftPM):
            #expect(name == "Package.swift")
            #expect(swiftPM.manifest.resolvingSymlinksInPath().path == project.resolvingSymlinksInPath().path)
        case .xcode(let xcode):
            #expect(name != "Package.swift")
            #expect(xcode.container.resolvingSymlinksInPath().path == project.resolvingSymlinksInPath().path)
        }
    }

    @Test(arguments: ["", ".", "Sources/App.swift", "Package.txt", "App.xcodeproj/project.pbxproj"])
    func rejectsUnsupportedProjectPaths(project: String) throws {
        #expect(throws: StringError.self) {
            try PackSchema(validating: .init(version: .v1, orgID: "org.example", project: project))
        }
    }

    @Test func rejectsMissingConfiguredProject() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
        version: 1
        orgID: org.example
        project: Missing.xcodeproj
        """.utf8).write(to: directory.appending(path: "xtool.yml"))
        try Data().write(to: directory.appending(path: "Package.swift"))
        await #expect(throws: Console.Error.self) {
            try await XToolProject.discover(start: directory)
        }
    }

    @Test func discoversProjectWhenFieldIsOmitted() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
        version: 1
        orgID: org.example
        """.utf8).write(to: directory.appending(path: "xtool.yml"))
        try Data().write(to: directory.appending(path: "Package.swift"))

        let project = try await XToolProject.discover(start: directory)
        #expect(project.base.schema.project == nil)
        #expect(project.base.schema.orgID == "org.example")
        guard case .swiftPM(let swiftPM) = project else {
            Issue.record("Expected a Swift package")
            return
        }
        #expect(swiftPM.manifest.resolvingSymlinksInPath().path
            == directory.appending(path: "Package.swift").resolvingSymlinksInPath().path)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
