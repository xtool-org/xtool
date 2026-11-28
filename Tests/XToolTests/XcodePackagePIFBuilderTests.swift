import XCLIUtils
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import Subprocess
import SwiftBuild
import Testing
import XcodeProjects
import XPIF
import XUtils
@testable import XcodePIFConversion
@testable import XToolSupport

struct XcodePackagePIFBuilderTests {
    // TODO: needs an installed Darwin SDK on Linux
    #if os(macOS)
    @Test(.requiresXcode, .dependencies { $0.out.write = { _, _, _ in } })
    func resolvesPackagesDiscoveredInSynchronizedFolders() async throws {
        let fixtures = fixtureURL("Projects")
        let project = try XcodeProject(url: fixtures.appending(path: "DiscoveredPackages.xcodeproj"))
        #expect(project.project.packages.isEmpty)
        let builder = try XcodePIFBuilder(project: project)
        #expect(builder.packageReferences.count == 1)
        let loaded = try #require(builder.projects.values.first)
        #expect(!loaded.references.contains { $0.url?.lastPathComponent == "Account.swift" })
        let packages = try await XcodePackagePIFBuilder(builder: builder, rootDirectory: URL(filePath: ".")).build()
        let workspace = try builder.build(packageProjects: packages)
        let account = try #require(packages.flatMap(\.targets).first { $0.common.name == "Account-product" })
        #expect(workspace.projects[0].targets[0].common.dependencies.contains { $0.targetId == account.id })

        // An explicit declaration retains its traits and is not duplicated by discovery.
        var declared = project
        declared.project.packages = [.init(location: .local(.init(path: "Modules/Account")), traits: ["Feature"])]
        let references = try XcodePIFBuilder(project: declared).packageReferences
        #expect(references.count == 1)
        #expect(references[0].package.traits == ["Feature"])
        #expect(references[0].isRoot)
    }
    #endif

    @Test(arguments: [
        (XCSchema.SwiftPackageVersionConstraint.revision("abc123"), "revision: \"abc123\""),
        (.branch("feature/\"quoted\""), "branch: \"feature/\\\"quoted\\\"\""),
        (.version("1.2.3"), "exact: \"1.2.3\""),
        (.versionRange(min: "1.0.0", max: "2.0.0"), "\"1.0.0\"..<\"2.0.0\""),
        (.upToNextMinorVersion("1.2.3"), ".upToNextMinor(from: \"1.2.3\")"),
        (.upToNextMajorVersion("1.2.3"), "from: \"1.2.3\""),
    ])
    func manifestRequirements(constraint: XCSchema.SwiftPackageVersionConstraint, expected: String) throws {
        let reference = remote(constraint)
        let manifest = try XcodePackagePIFBuilder.manifest(references: [reference])
        expectNoDifference(manifest, """
        // swift-tools-version: 6.1
        import PackageDescription

        let package = Package(
            name: "XtoolDependencies",
            dependencies: [
                .package(url: "https://example.com/Library.git", \(expected)),
            ]
        )

        """)
    }

    @Test func deduplicatesReferencesAndResolvesLocalPaths() throws {
        let root = URL(filePath: "/tmp/Projects", directoryHint: .isDirectory).resolvingSymlinksInPath()
        let first = XcodePIFBuilder.PackageReference(sourceRoot: root, package: .init(
            location: .local(.init(path: "Library")), traits: ["Z", "A"]
        ))
        let second = XcodePIFBuilder.PackageReference(sourceRoot: root.appending(path: "Nested"), package: .init(
            location: .local(.init(path: "../Library")), traits: ["A", "Z"]
        ))
        let manifest = try XcodePackagePIFBuilder.manifest(references: [first, second])
        #expect(manifest.components(separatedBy: ".package(").count == 2)
        #expect(manifest.contains("path: \(String(reflecting: root.appending(path: "Library").path))"))
        #expect(manifest.contains("traits: [\"A\", \"Z\"]"))
        let remote = remote(.version("1.2.3"))
        #expect(throws: Console.Error.self) { try XcodePackagePIFBuilder.manifest(references: [first, remote]) }
        #expect(throws: Console.Error.self) {
            try XcodePackagePIFBuilder.manifest(references: [remote, self.remote(.branch("main"))])
        }
        #expect(throws: Console.Error.self) { try XcodePackagePIFBuilder.manifest(references: [self.remote(nil)]) }
    }

    // TODO: needs an installed Darwin SDK on Linux
    #if os(macOS)
    @Test(.requiresXcode, .dependencies { $0.out.write = { _, _, _ in } })
    func buildsAppWithPackageResourcesAndTransitiveTarget() async throws {
        let temporary = try TemporaryDirectory(name: "PackageBuild")
        let fixtures = fixtureURL("Projects")
        #if os(macOS)
        let triple = "arm64-apple-ios-simulator"
        #else
        let triple = "arm64-apple-ios"
        #endif
        let description = try await XToolProject.testXcode(fixtures.appending(path: "Packages.xcodeproj"))
            .describe(configuration: .debug, triple: triple)
        let package = try #require(description.pif.workspace.projects.first { $0.id == "PACKAGE:localpackage" })
        #expect(package.targets.contains { $0.common.name == "Helper" })
        #expect(!package.targets.contains { $0.common.name.contains("Tests") })
        let coordinator = try await BuildCoordinator(description: description)
        do {
            var request = await coordinator.buildRequest
            let guid = try await coordinator.mainProductGUID()
            request.configuredTargets = [SWBConfiguredTarget(guid: guid)]
            request.parameters.overrides.synthesized?.set(value: "NO", for: "CODE_SIGNING_ALLOWED")
            request.parameters.overrides.synthesized?.set(value: "NO", for: "COMPILER_INDEX_STORE_ENABLE")
            let derived = temporary.url.appending(path: "DerivedData")
            request.parameters.arenaInfo = SWBArenaInfo(
                derivedDataPath: derived.path, buildProductsPath: derived.appending(path: "Products").path,
                buildIntermediatesPath: derived.appending(path: "Intermediates").path, pchPath: derived.path,
                indexRegularBuildProductsPath: nil, indexRegularBuildIntermediatesPath: nil,
                indexPCHPath: derived.path, indexDataStoreFolderPath: nil, indexEnableDataStore: false
            )
            let manager = await coordinator.sessionManager
            let output = URL(filePath: try await manager.session.evaluateMacroAsString(
                "TARGET_BUILD_DIR", level: .target(guid),
                buildParameters: request.parameters, overrides: nil
            ))
            let operation = try await manager.createBuildOperation(request: request)
            var errors: [String] = []
            for await event in try await operation.start() {
                if case .diagnostic(let diagnostic) = event, diagnostic.kind == .error { errors.append(diagnostic.message) }
            }
            await operation.waitForCompletion()
            #expect(operation.state == .succeeded, "Build errors: \(errors)")
            #expect(FileManager.default.fileExists(atPath: output.appending(path: "App.app/App").path))
            let resource = output.appending(path: "App.app/LocalPackage_Library.bundle/Message.txt")
            expectNoDifference(try String(contentsOf: resource, encoding: .utf8), "Package fixture\n")
            await coordinator.close()
        } catch {
            await coordinator.close()
            throw error
        }
    }

    @Test(.requiresXcode, .dependencies { $0.out.write = { _, _, _ in } })
    func resolvesGitPackageAtRequestedVersion() async throws {
        let temporary = try TemporaryDirectory(name: "GitPackage")
        let fixtures = fixtureURL("Projects")
        let repository = temporary.url.appending(path: "RemoteLibrary")
        try FileManager.default.copyItem(at: fixtures.appending(path: "LocalPackage"), to: repository)
        for arguments in [
            ["init", "--initial-branch=main"], ["add", "."],
            ["-c", "user.name=Package Test", "-c", "user.email=package@example.com", "commit", "-m", "Fixture"],
            ["tag", "1.2.3"],
        ] {
            _ = try await Subprocess.run(
                .name("git"), arguments: .init(["-C", repository.path] + arguments),
                output: .discarded, error: .discarded
            ).checkSuccess()
        }
        var project = try XcodeProject(url: fixtures.appending(path: "Packages.xcodeproj"))
            .withURL(temporary.url.appending(path: "App.xcodeproj"))
        project.project.packages = [.init(location: .remote(.init(
            repositoryURL: repository.absoluteString, versionConstraint: .version("1.2.3")
        )), traits: [])]
        let builder = try XcodePIFBuilder(project: project)
        let packages = try await XcodePackagePIFBuilder(builder: builder, rootDirectory: URL(filePath: ".")).build()
        let package = try #require(packages.first { $0.id == "PACKAGE:remotelibrary" })
        #expect(package.projectDir.contains("/checkouts/RemoteLibrary"))
        let product = try #require(package.targets.first { $0.common.name == "Library-product" })
        let workspace = try builder.build(packageProjects: packages)
        #expect(workspace.projects[0].targets[0].common.dependencies.contains { $0.targetId == product.id })
        #expect(FileManager.default.fileExists(atPath: URL(filePath: package.projectDir).appending(path: "Package.swift").path))
    }
    #endif

    private func remote(_ constraint: XCSchema.SwiftPackageVersionConstraint?) -> XcodePIFBuilder.PackageReference {
        .init(sourceRoot: URL(filePath: "/tmp"), package: .init(location: .remote(.init(
            repositoryURL: "https://example.com/Library.git", versionConstraint: constraint
        )), traits: []))
    }
}
