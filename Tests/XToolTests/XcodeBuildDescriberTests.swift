import XCLIUtils
import CustomDump
import XUtils
import XPIF
import Foundation
import Testing
@testable import XToolSupport
import DependenciesTestSupport

struct XcodeBuildDescriberTests {
    @Test func decodesXcodePIFWithoutLosingSettings() throws {
        let data = try fixtureData()
        var pif = try XPIF.Container(data: data)
        #expect(pif.workspace.projects[0].name == "Probe")
        #expect(!pif.workspace.projects[0].isPackage)
        #expect(pif.workspace.projects[0].targets[0].common.name == "Probe")
        let decoded = try XPIF.Container(data: pif.data())
        #expect(decoded.workspace.projects[0].targets.map(\.id) == pif.workspace.projects[0].targets.map(\.id))
        pif.workspace.name = "Changed"
        #expect(try XPIF.Container(data: pif.data()).workspace.name == "Changed")
    }

    @Test(.dependencies {
        $0.out.write = { _, _, _ in }
    })
    func detectsProjectsAndPrefersWorkspacesThenProjectsThenSwiftPackages() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: Console.Error.self) { try await XToolProject.discover(start: directory) }
        try Data().write(to: directory.appending(path: "Package@swift-6.4.swift"))
        guard case .swiftPM = try await XToolProject.discover(start: directory) else {
            Issue.record("Expected a Swift package")
            return
        }
        let project = directory.appending(path: "App.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        guard case .xcode(let detected) = try await XToolProject.discover(start: directory) else {
            Issue.record("Expected an Xcode project")
            return
        }
        #expect(detected.container.resolvingSymlinksInPath().path == project.resolvingSymlinksInPath().path)
        try FileManager.default.createDirectory(at: directory.appending(path: "Other.xcodeproj"), withIntermediateDirectories: true)
        await #expect(throws: Console.Error.self) { try await XToolProject.discover(start: directory) }
        let workspace = directory.appending(path: "App.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        guard case .xcode(let detectedWorkspace) = try await XToolProject.discover(start: directory) else {
            Issue.record("Expected an Xcode workspace")
            return
        }
        #expect(detectedWorkspace.container.resolvingSymlinksInPath().path == workspace.resolvingSymlinksInPath().path)
        try FileManager.default.createDirectory(at: directory.appending(path: "Other.xcworkspace"), withIntermediateDirectories: true)
        await #expect(throws: Console.Error.self) { try await XToolProject.discover(start: directory) }
    }

    @Test func generatesPIFWithoutXcode() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let project = directory.appending(path: "Probe.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = fixtureURL("simple-xcode-project.pbxproj")
        try FileManager.default.copyItem(at: fixture, to: project.appending(path: "project.pbxproj"))
        try Data("import UIKit\n".utf8).write(to: directory.appending(path: "App.swift"))
        let description = try await XToolProject.testXcode(project).describe(configuration: .debug, triple: "arm64-apple-ios")
        #expect(description.configuration == .debug)
        #expect(try !description.pif.data().isEmpty)
        let targets = description.pif.workspace.projects.flatMap(\.targets)
        let umbrella = try #require(targets.first { $0.id == "xtool:UMBRELLA" })
        guard case .aggregate(let aggregate) = umbrella else {
            Issue.record("Expected an aggregate umbrella target")
            return
        }
        let app = try #require(targets.first { $0.id != umbrella.id })
        expectNoDifference(aggregate.common.dependencies.map(\.targetId), [app.id])
        expectNoDifference(aggregate.common.buildConfigs.map(\.name), ["Debug", "Release"])
    }

    private func fixtureData() throws -> Data {
        let url = fixtureURL("xcode-project.json")
        return try Data(contentsOf: url)
    }
}
