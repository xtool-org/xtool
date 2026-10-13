import Dependencies
import Foundation
import Testing
@testable import PackLib

struct BundleAssemblerTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String = "fixture", at url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: url.path) }
    }

    private func product(
        _ name: String = "App", kind: Plan.ProductType = .application, resources: [Plan.Resource] = []
    ) throws -> Plan.Product {
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        return Plan.Product(target: target, type: kind, product: name, bundleID: "test.\(name)",
                            infoPlist: ["CFBundleExecutable": name, "CFBundleIdentifier": "test.\(name)",
                                        "CallerKey": "preserved"], resources: resources)
    }

    private func artifacts(_ plan: Plan, in root: URL) throws -> BuildArtifacts {
        let directory = root.appendingPathComponent("build")
        var executables: [String: URL] = [:]
        for product in plan.allProducts {
            let executable = directory.appendingPathComponent(product.targetName)
            try write(at: executable, executable: true)
            executables[product.product] = executable
        }
        return BuildArtifacts(directory: directory, executables: executables)
    }

    @Test func nestedProductsAndMetadataPreserveInputs() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appendingPathComponent("agent.plist")
        try write("caller launch agent metadata", at: agent)
        let destination = ResourceDestination(location: .contents, path: "Library/LaunchAgents/test.plist")
        let app = try product(resources: [.copy(.init(source: "agent.plist", destination: destination))])
        let ext = try product("Preview", kind: .appExtension)
        let xpc = try product("Service", kind: .xpcService)
        let helper = try product("Helper", kind: .helperExecutable)
        let plan = try Plan(target: app.target, app: app, extensions: [ext], nestedProducts: [xpc, helper])
        let artifacts = try artifacts(plan, in: root)
        let output = root.appendingPathComponent("App.app")
        try BundleAssembler(plan: plan, sourceDirectory: root).assemble(artifacts: artifacts, at: output)
        for product in plan.allProducts {
            let executable = output.appendingPathComponent(product.layout.executablePath)
            #expect(FileManager.default.isExecutableFile(atPath: executable.path))
            let permissions = try FileManager.default.attributesOfItem(atPath: executable.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o751)
            if let path = product.layout.infoPlistPath {
                let data = try Data(contentsOf: output.appendingPathComponent(path))
                let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
                #expect(info["CallerKey"] == "preserved")
                #expect(info["CFBundleExecutable"] == product.product)
                #expect(info["LSRequiresIPhoneOS"] == nil)
            }
        }
        let extPath = "Contents/PlugIns/Preview.appex/Contents/MacOS/Preview"
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(extPath).path))
        let xpcPath = "Contents/XPCServices/Service.xpc/Contents/MacOS/Service"
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(xpcPath).path))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("Contents/Helpers/Helper").path))
        let agentCopy = output.appendingPathComponent("Contents/Library/LaunchAgents/test.plist")
        #expect(try Data(contentsOf: agentCopy) == Data(contentsOf: agent))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("Contents/Helpers/Info.plist").path))
    }

    private func framework(_ name: String, in directory: URL, binary: String = "dynamic fixture") throws -> URL {
        let framework = directory.appendingPathComponent("\(name).framework")
        try write(binary, at: framework.appendingPathComponent("Versions/A/\(name)"), executable: true)
        try write("framework metadata", at: framework.appendingPathComponent("Versions/A/Resources/Info.plist"))
        for (path, target) in [("Versions/Current", "A"), (name, "Versions/Current/\(name)"),
                               ("Resources", "Versions/Current/Resources")] {
            try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent(path).path,
                                                       withDestinationPath: target)
        }
        return framework
    }

    @Test func frameworksStayIntactAndArchivesAreExcluded() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try product(resources: [.binaryTarget(name: "Dynamic"), .binaryTarget(name: "Static"),
                                          .binaryTarget(name: "Thin"), .library(name: "Shared")])
        let plan = try Plan(target: app.target, app: app)
        let artifacts = try artifacts(plan, in: root)
        _ = try framework("Dynamic", in: artifacts.directory)
        _ = try framework("Static", in: artifacts.directory, binary: "!<arch>\narchive fixture")
        _ = try framework("Thin", in: artifacts.directory, binary: "!<thin>\narchive fixture")
        try write("dynamic library", at: artifacts.directory.appendingPathComponent("libShared.dylib"))
        let output = root.appendingPathComponent("App.app")
        try BundleAssembler(plan: plan, sourceDirectory: root).assemble(artifacts: artifacts, at: output)
        let copied = output.appendingPathComponent("Contents/Frameworks/Dynamic.framework")
        let current = copied.appendingPathComponent("Versions/Current")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: current.path) == "A")
        let binary = copied.appendingPathComponent("Dynamic")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: binary.path) == "Versions/Current/Dynamic")
        #expect(try String(contentsOf: copied.appendingPathComponent("Resources/Info.plist"), encoding: .utf8) == "framework metadata")
        #expect(FileManager.default.isExecutableFile(atPath: copied.appendingPathComponent("Dynamic").path))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("Contents/Frameworks/Static.framework").path))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("Contents/Frameworks/Thin.framework").path))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("Contents/Frameworks/libShared.dylib").path))
    }

    @Test func validatedLooseStaticTargetIsNotEmbeddedAndMissingArchiveFails() throws {
        let packageRoot = try root()
        defer { try? FileManager.default.removeItem(at: packageRoot) }
        let app = try product(resources: [.binaryTarget(name: "StaticProbe")])
        let plan = try Plan(target: app.target, app: app)
        let built = try artifacts(plan, in: packageRoot)
        try write("!<arch>\nstatic archive fixture", at: built.directory.appendingPathComponent("libStaticProbe.a"))
        let marked = BuildArtifacts(directory: built.directory, executables: built.executables,
                                    staticBinaryTargets: ["StaticProbe"])
        let output = packageRoot.appendingPathComponent("App.app")
        try BundleAssembler(plan: plan, sourceDirectory: packageRoot).assemble(artifacts: marked, at: output)
        let embeddedStaticFramework = output.appendingPathComponent("Contents/Frameworks/StaticProbe.framework")
        #expect(!FileManager.default.fileExists(atPath: embeddedStaticFramework.path))

        let missingRoot = try self.root()
        defer { try? FileManager.default.removeItem(at: missingRoot) }
        let missingBuilt = try artifacts(plan, in: missingRoot)
        let missing = BuildArtifacts(directory: missingBuilt.directory, executables: missingBuilt.executables,
                                     staticBinaryTargets: ["StaticProbe"])
        #expect(throws: (any Error).self) {
            try BundleAssembler(plan: plan, sourceDirectory: missingRoot)
                .assemble(artifacts: missing, at: missingRoot.appendingPathComponent("Missing.app"))
        }
    }

    @Test func preparedAssetsAndIconAreCopied() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("prepared icon", at: root.appendingPathComponent("Icon.icns"))
        try write("prepared assets", at: root.appendingPathComponent("Assets.car"))
        var app = try product(resources: [.copy(.init(source: "Assets.car", destination: .init(path: "Assets.car")))])
        app.iconPath = "Icon.icns"
        app.infoPlist["CFBundleIconFile"] = "CallerIconName"
        let plan = try Plan(target: app.target, app: app)
        let artifacts = try artifacts(plan, in: root)
        let output = root.appendingPathComponent("App.app")
        try BundleAssembler(plan: plan, sourceDirectory: root).assemble(artifacts: artifacts, at: output)
        let iconCopy = output.appendingPathComponent("Contents/Resources/Icon.icns")
        #expect(try String(contentsOf: iconCopy, encoding: .utf8) == "prepared icon")
        let assetsCopy = output.appendingPathComponent("Contents/Resources/Assets.car")
        #expect(try String(contentsOf: assetsCopy, encoding: .utf8) == "prepared assets")
        let info = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: output.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: String])
        #expect(info["CFBundleIconFile"] == "CallerIconName")
    }

    @Test(arguments: ["Assets.xcassets", "Icon.iconset", "Window.storyboard", "Window.xib"])
    func rawAssetsRejectWithActionableMessage(name: String) throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(at: root.appendingPathComponent(name))
        let app = try product(resources: [.root(source: name)])
        let plan = try Plan(target: app.target, app: app)
        let artifacts = try artifacts(plan, in: root)
        do {
            try BundleAssembler(plan: plan, sourceDirectory: root)
                .assemble(artifacts: artifacts, at: root.appendingPathComponent("App.app"))
            Issue.record("Expected raw asset rejection")
        } catch {
            #expect(String(describing: error).contains("supply prepared Assets.car, .icns"))
        }
    }

    @Test(arguments: ["../escape", "/absolute", "Contents/../escape", "a//b", "a\\b"])
    func traversalRejectsBeforeWriting(path: String) throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try product(resources: [.copy(.init(source: "input", destination: .init(path: path)))])
        let plan = try Plan(target: app.target, app: app)
        let artifacts = try artifacts(plan, in: root)
        let output = root.appendingPathComponent("App.app")
        #expect(throws: (any Error).self) {
            try BundleAssembler(plan: plan, sourceDirectory: root).assemble(artifacts: artifacts, at: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(arguments: ["same", "SAME", "same/child"])
    func duplicateAndAncestorDestinationsReject(path: String) throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(at: root.appendingPathComponent("input"))
        let app = try product(resources: ["same", path].map {
            .copy(.init(source: "input", destination: .init(path: $0)))
        })
        let plan = try Plan(target: app.target, app: app)
        let artifacts = try artifacts(plan, in: root)
        #expect(throws: (any Error).self) {
            try BundleAssembler(plan: plan, sourceDirectory: root)
                .assemble(artifacts: artifacts, at: root.appendingPathComponent("App.app"))
        }
    }

    @Test func resourcesCannotReplaceBundleStructure() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(at: root.appendingPathComponent("input"))
        let app = try product(resources: [.copy(.init(source: "input", destination: .init(location: .bundle, path: "Contents")))])
        let plan = try Plan(target: app.target, app: app)
        let artifacts = try artifacts(plan, in: root)
        #expect(throws: (any Error).self) {
            try BundleAssembler(plan: plan, sourceDirectory: root)
                .assemble(artifacts: artifacts, at: root.appendingPathComponent("App.app"))
        }
    }

    @Test(arguments: [Plan.Resource.root(source: "absent"), .bundle(package: "Missing", target: "Resources"),
                      .binaryTarget(name: "Missing"), .library(name: "Missing")])
    func missingInputsReject(resource: Plan.Resource) throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try product(resources: [resource])
        let plan = try Plan(target: app.target, app: app)
        let artifacts = try artifacts(plan, in: root)
        #expect(throws: (any Error).self) {
            try BundleAssembler(plan: plan, sourceDirectory: root)
                .assemble(artifacts: artifacts, at: root.appendingPathComponent("App.app"))
        }
    }

    @Test(arguments: ["Missing", "../../../outside", "/tmp/outside"])
    func brokenAndEscapingFrameworkSymlinksReject(target: String) throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try product(resources: [.binaryTarget(name: "Dynamic")])
        let plan = try Plan(target: app.target, app: app)
        let artifacts = try artifacts(plan, in: root)
        let framework = try framework("Dynamic", in: artifacts.directory)
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("BadLink").path,
                                                   withDestinationPath: target)
        #expect(throws: (any Error).self) {
            try BundleAssembler(plan: plan, sourceDirectory: root)
                .assemble(artifacts: artifacts, at: root.appendingPathComponent("App.app"))
        }
    }

    @Test func missingExecutableAndUnsafeProductNamesReject() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["App", "../escape"] {
            let app = try product(name)
            let plan = try Plan(target: app.target, app: app)
            #expect(throws: (any Error).self) {
                try BundleAssembler(plan: plan, sourceDirectory: root)
                    .assemble(artifacts: .init(directory: root, executables: [:]), at: root.appendingPathComponent("App.app"))
            }
        }
    }

    @Test func iosLayoutAndLegacyRootResourcesRemainFlat() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-ios17.0")
        let app = Plan.Product(target: target, type: .application, product: "App", bundleID: "test.App", infoPlist: [:],
                               resources: [.root(source: "legacy.txt"), .bundle(package: "Package", target: "Target")])
        let plan = try Plan(target: target, app: app)
        let artifacts = try artifacts(plan, in: root)
        try write(at: root.appendingPathComponent("legacy.txt"))
        try write(at: artifacts.directory.appendingPathComponent("Package_Target.bundle/resource.txt"))
        let output = root.appendingPathComponent("App.app")
        try BundleAssembler(plan: plan, sourceDirectory: root).assemble(artifacts: artifacts, at: output)
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("App").path))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("legacy.txt").path))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("Package_Target.bundle/resource.txt").path))
        let info = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: output.appendingPathComponent("Info.plist")), format: nil) as? [String: Any])
        #expect(info["LSRequiresIPhoneOS"] as? Bool == true)
        #expect(info["CFBundleSupportedPlatforms"] as? [String] == ["iPhoneOS"])
    }

    #if os(macOS)
    @Test func generatedSwiftPMAccessorFindsRelocatedResources() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package")
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "RelocationFixture", platforms: [.macOS("15.0")],
                              products: [.executable(name: "Reader", targets: ["Reader"])],
                              targets: [.executableTarget(name: "Reader", resources: [.copy("message.txt")])])
        """
        try write(manifest, at: package.appendingPathComponent("Package.swift"))
        try write("relocated resource", at: package.appendingPathComponent("Sources/Reader/message.txt"))
        try write("""
        import Foundation
        let file = Bundle.module.url(forResource: "message", withExtension: "txt")!
        print(try String(contentsOf: file, encoding: .utf8))
        """, at: package.appendingPathComponent("Sources/Reader/main.swift"))
        var app = try product(resources: [.bundle(package: "RelocationFixture", target: "Reader")])
        app.source = .executable(product: "Reader")
        let plan = try Plan(target: app.target, app: app)
        let settings = try await BuildSettings(configuration: .debug, triple: app.target.triple, buildSystem: .swiftPM,
                                               packagePath: package.path)
        let artifacts = try await withDependencies {
            $0.productBuildRunner = .liveValue
        } operation: {
            try await ProductBuilder(buildSettings: settings, plan: plan).build()
        }
        let output = root.appendingPathComponent("App.app")
        try BundleAssembler(plan: plan, sourceDirectory: package).assemble(artifacts: artifacts, at: output)
        let relocated = root.appendingPathComponent("elsewhere/App.app")
        try FileManager.default.createDirectory(at: relocated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: output, to: relocated)
        try FileManager.default.removeItem(at: package)
        let link = relocated.appendingPathComponent("RelocationFixture_Reader.bundle")
        let resourcePath = "Contents/Resources/RelocationFixture_Reader.bundle"
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == resourcePath)
        #expect(try String(contentsOf: link.appendingPathComponent("message.txt"), encoding: .utf8) == "relocated resource")
        let process = Process()
        process.executableURL = relocated.appendingPathComponent("Contents/MacOS/App")
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == "relocated resource\n")
    }
    #endif
}
