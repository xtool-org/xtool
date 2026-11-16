import XCLIUtils
import ArgumentParser
import CustomDump
import DependenciesTestSupport
import Foundation
import Testing
import XcodeProjects
import XcodePIFConversion
import XPIF
import XUtils
@testable import XToolSupport

struct XcodeSchemeTests {
    @Test(arguments: ["Primary", "Secondary"])
    func selectsTargetsAcrossProjects(scheme: String) async throws {
        let description = try await describe(scheme: scheme)
        let selection = try #require(description.targetSelection)
        let projectName = scheme == "Primary" ? "App" : "OtherApp"
        let app = try #require(description.pif.workspace.projects.first { $0.name == projectName }?.targets.first)
        expectNoDifference(selection.application, app.id)
        expectNoDifference(description.configuration, .debug) // The CLI configuration still takes precedence.
        if scheme == "Primary" {
            expectNoDifference(selection.buildTargets, [app.id])
            #expect(selection.buildImplicitDependencies)
        } else {
            let framework = try #require(description.pif.workspace.projects.first { $0.name == "Features" }?.targets.first)
            expectNoDifference(selection.buildTargets, [framework.id, app.id])
            #expect(!selection.buildImplicitDependencies)
        }
        let original = try await describe(scheme: nil)
        #expect(original.targetSelection == nil)
        expectNoDifference(try description.pif.data(), try original.pif.data())
        let targets = description.pif.workspace.projects.flatMap(\.targets)
        let umbrella = try #require(targets.first { $0.id == "xtool:UMBRELLA" })
        expectNoDifference(umbrella.common.dependencies.map(\.targetId),
                           targets.filter { $0.id != umbrella.id }.map(\.id))
    }

    @Test func findsSchemeForStandaloneProject() async throws {
        let description = try await describe(scheme: "Primary", container: "App.xcodeproj")
        let selection = try #require(description.targetSelection)
        let app = try #require(description.pif.workspace.projects.first { $0.name == "App" }?.targets.first)
        expectNoDifference(selection.application, app.id)
    }

    @Test func selectsPBXTargetUsingOriginalIdentifier() async throws {
        let temporary = try TemporaryDirectory(name: "Schemes")
        let root = temporary.url.appending(path: "Projects")
        try FileManager.default.copyItem(at: projects(), to: root)
        let projectURL = root.appending(path: "App.xcodeproj")
        try XcodeProject(url: projectURL).withFormat(.pbxproj).write()
        try FileManager.default.removeItem(at: projectURL.appending(path: "project.xcproj"))
        let description = try await describe(scheme: "Primary", container: "App.xcodeproj", root: root)
        let app = try #require(description.pif.workspace.projects.first { $0.name == "App" }?.targets.first)
        expectNoDifference(description.targetSelection?.application, app.id)
    }

    @Test(arguments: [true, false])
    func roundTripsWrittenScheme(shared: Bool) async throws {
        let temporary = try TemporaryDirectory(name: "Schemes")
        let root = temporary.url.appending(path: "Projects")
        try FileManager.default.copyItem(at: projects(), to: root)
        let workspace = root.appending(path: "Schemes.xcworkspace")
        let original = try XcodeScheme(named: "Secondary", containers: [workspace])
        let originalSelection = try #require(try await describe(scheme: "Secondary", root: root).targetSelection)
        try FileManager.default.removeItem(at: workspace.appending(path: "xcshareddata/xcschemes/Secondary.xcscheme"))
        try original.write(in: workspace, shared: shared)
        let written = try XcodeScheme(named: "Secondary", containers: [workspace])
        expectNoDifference(written.buildTargets.map(\.projectURL), original.buildTargets.map(\.projectURL))
        expectNoDifference(written.buildTargets.map(\.objectID), original.buildTargets.map(\.objectID))
        expectNoDifference(written.buildTargets.map(\.buildableName), original.buildTargets.map(\.buildableName))
        expectNoDifference(written.runnable?.objectID, original.runnable?.objectID)
        expectNoDifference(written.buildImplicitDependencies, original.buildImplicitDependencies)
        let selection = try #require(try await describe(scheme: "Secondary", root: root).targetSelection)
        expectNoDifference(selection.application, originalSelection.application)
        expectNoDifference(selection.buildTargets, originalSelection.buildTargets)
        expectNoDifference(selection.buildImplicitDependencies, originalSelection.buildImplicitDependencies)
    }

    @Test func rejectsUnknownScheme() async throws {
        await #expect(throws: XcodeScheme.SchemeError.self) { try await describe(scheme: "Missing") }
    }

    @Test(arguments: [false, true])
    func discoversUserSchemesAndRejectsDuplicateNames(duplicate: Bool) throws {
        let temporary = try TemporaryDirectory(name: "Schemes")
        let project = temporary.url.appending(path: "App.xcodeproj")
        let source = projects().appending(path: "App.xcodeproj/xcshareddata/xcschemes/Primary.xcscheme")
        let userSchemes = project.appending(path: "xcuserdata/\(NSUserName()).xcuserdatad/xcschemes")
        try FileManager.default.createDirectory(at: userSchemes, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: userSchemes.appending(path: "Primary.xcscheme"))
        if duplicate {
            let other = temporary.url.appending(path: "Other.xcodeproj")
            let shared = other.appending(path: "xcshareddata/xcschemes")
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: shared.appending(path: "Primary.xcscheme"))
            #expect(throws: XcodeScheme.SchemeError.self) {
                try XcodeScheme(named: "Primary", containers: [project, other])
            }
        } else {
            let scheme = try XcodeScheme(named: "Primary", containers: [project, project])
            expectNoDifference(scheme.buildTargets.map(\.projectURL.path), [project.resolvingSymlinksInPath().path])
        }
    }

    @Test(arguments: [
        ("A50000000000000000000001", "MISSING"),
        ("container:OtherApp.xcodeproj", "container:Missing.xcodeproj"),
    ])
    func rejectsUnresolvedTargets(original: String, replacement: String) async throws {
        let temporary = try TemporaryDirectory(name: "Schemes")
        let root = temporary.url.appending(path: "Projects")
        try FileManager.default.copyItem(at: projects(), to: root)
        let scheme = root.appending(path: "Schemes.xcworkspace/xcshareddata/xcschemes/Secondary.xcscheme")
        let xml = try String(contentsOf: scheme, encoding: .utf8)
        try xml.replacingOccurrences(of: original, with: replacement).write(to: scheme, atomically: true, encoding: .utf8)
        await #expect(throws: XcodePIFConversionError.self) {
            try await describe(scheme: "Secondary", root: root)
        }
    }

    @Test(arguments: [false, true])
    func rejectsEmptyOrAmbiguousApplicationSelection(empty: Bool) async throws {
        let temporary = try TemporaryDirectory(name: "Schemes")
        let root = temporary.url.appending(path: "Projects")
        try FileManager.default.copyItem(at: projects(), to: root)
        let scheme = root.appending(path: "Schemes.xcworkspace/xcshareddata/xcschemes/Secondary.xcscheme")
        var xml = try String(contentsOf: scheme, encoding: .utf8)
        if empty {
            xml = xml.replacingOccurrences(of: "buildForRunning=\"YES\"", with: "buildForRunning=\"NO\"")
        } else {
            let launch = try #require(xml.range(of: "  <LaunchAction"))
            xml = String(xml[..<launch.lowerBound]) + "</Scheme>\n"
            xml = xml.replacingOccurrences(of: "buildForRunning=\"NO\"", with: "buildForRunning=\"YES\"")
        }
        try xml.write(to: scheme, atomically: true, encoding: .utf8)
        await #expect(throws: Console.Error.self) { try await describe(scheme: "Secondary", root: root) }
    }

    @Test(.dependencies { $0.out.write = { _, _, _ in } })
    func usesConfiguredSchemeAndAllowsCLIOverride() async throws {
        let temporary = try TemporaryDirectory(name: "Schemes")
        let root = temporary.url.appending(path: "Projects")
        try FileManager.default.copyItem(at: projects(), to: root)
        try Data("""
        version: 1
        orgID: org.example
        project: Schemes.xcworkspace
        scheme: Secondary
        skipLSP: true
        """.utf8).write(to: root.appending(path: "xtool.yml"))
        let project = try await XToolProject.discover(start: root)
        let configured = try await project.describe(configuration: .debug, triple: triple)
        let overridden = try await project.describe(configuration: .debug, triple: triple, scheme: "Primary")
        let other = try #require(configured.pif.workspace.projects.first { $0.name == "OtherApp" }?.targets.first)
        let app = try #require(configured.pif.workspace.projects.first { $0.name == "App" }?.targets.first)
        expectNoDifference(configured.targetSelection?.application, other.id)
        expectNoDifference(overridden.targetSelection?.application, app.id)
    }

    @Test func rejectsRunnableOutsideBuildSelection() async throws {
        let temporary = try TemporaryDirectory(name: "Schemes")
        let root = temporary.url.appending(path: "Projects")
        try FileManager.default.copyItem(at: projects(), to: root)
        let scheme = root.appending(path: "Schemes.xcworkspace/xcshareddata/xcschemes/Secondary.xcscheme")
        let xml = try String(contentsOf: scheme, encoding: .utf8)
        let launch = try #require(xml.range(of: "  <LaunchAction"))
        let changed = String(xml[..<launch.lowerBound]) + xml[launch.lowerBound...]
            .replacingOccurrences(of: "container:OtherApp.xcodeproj", with: "container:App.xcodeproj")
        try changed.write(to: scheme, atomically: true, encoding: .utf8)
        await #expect(throws: Console.Error.self) { try await describe(scheme: "Secondary", root: root) }
    }

    @Test(.dependencies { $0.out.write = { _, _, _ in } })
    func rejectsSchemeForSwiftPackage() async throws {
        let temporary = try TemporaryDirectory(name: "Schemes")
        try Data().write(to: temporary.url.appending(path: "Package.swift"))
        let project = try await XToolProject.discover(start: temporary.url)
        await #expect(throws: Console.Error.self) {
            try await project.describe(configuration: .debug, triple: triple, scheme: "Primary")
        }
    }

    @Test func parsesCLIOptions() throws {
        expectNoDifference(try DevBuildCommand.parse(["--scheme", "Secondary"]).packOptions.scheme, "Secondary")
        expectNoDifference(try DevRunCommand.parse(["--scheme", "Primary"]).packOptions.scheme, "Primary")
        expectNoDifference(try DevBSPCommand.parse(["--scheme", "Secondary"]).scheme, "Secondary")
    }

    // TODO: needs an installed Darwin SDK on Linux
    #if os(macOS)
    @Test(.requiresXcode) func configuresBuildServiceWithSchemeTargets() async throws {
        let description = try await describe(scheme: "Secondary")
        let selection = try #require(description.targetSelection)
        let coordinator = try await BuildCoordinator(description: description)
        do {
            let productGUID = try await coordinator.mainProductGUID()
            expectNoDifference(productGUID, selection.application.value)
            let request = await coordinator.buildRequest
            expectNoDifference(request.configuredTargets.map(\.guid), selection.buildTargets.map(\.value))
            #expect(!request.useImplicitDependencies)
            let details = try await coordinator.mainProductDetails()
            expectNoDifference(details.productName, "OtherApp")
            await coordinator.close()
        } catch {
            await coordinator.close()
            throw error
        }
    }
    #endif

    private func projects() -> URL {
        fixtureURL("Projects")
    }

    private let triple = "arm64-apple-ios-simulator"

    private func describe(
        scheme: String?, container: String = "Schemes.xcworkspace", root: URL? = nil
    ) async throws -> BuildDescription {
        try await XToolProject.testXcode((root ?? projects()).appending(path: container))
            .describe(configuration: .debug, triple: triple, scheme: scheme)
    }
}
