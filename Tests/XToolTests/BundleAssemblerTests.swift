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
        let helper = try product("Helper", kind: .helperExecutable,
                                 resources: [.copy(.init(source: "agent.plist", destination: .init(path: "Helper.plist")))])
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
        #expect(try Data(contentsOf: output.appendingPathComponent("Contents/Resources/Helper.plist")) == Data(contentsOf: agent))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("Contents/Helpers/Info.plist").path))
    }

    @Test func macOSResourceBundlesNeverCreateBundleRootAliases() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources: [Plan.Resource] = [.bundle(package: "Package", target: "Resources")]
        let app = try product(resources: resources)
        let ext = try product("Preview", kind: .appExtension, resources: resources)
        let xpc = try product("Service", kind: .xpcService, resources: resources)
        let plan = try Plan(target: app.target, app: app, extensions: [ext], nestedProducts: [xpc])
        let artifacts = try artifacts(plan, in: root)
        try write(at: artifacts.directory.appendingPathComponent("Package_Resources.bundle/message.txt"))
        let output = root.appendingPathComponent("App.app")
        try BundleAssembler(plan: plan, sourceDirectory: root).assemble(artifacts: artifacts, at: output)
        for product in plan.allProducts {
            let bundle = output.appendingPathComponent(product.layout.bundlePath)
            #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.path) == ["Contents"])
            let resource = output.appendingPathComponent(product.layout.resourcesPath + "/Package_Resources.bundle/message.txt")
            #expect(try String(contentsOf: resource, encoding: .utf8) == "fixture")
        }
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

    @Test func helpersShareGeneratedDependenciesAfterRelocation() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources: [Plan.Resource] = [.binaryTarget(name: "Dynamic"), .library(name: "Shared"),
                                          .bundle(package: "Shared", target: "Resources")]
        let app = try product()
        let helpers = try ["FirstHelper", "SecondHelper"].map {
            try product($0, kind: .helperExecutable, resources: resources)
        }
        let plan = try Plan(target: app.target, app: app, nestedProducts: helpers)
        let artifacts = try artifacts(plan, in: root)
        _ = try framework("Dynamic", in: artifacts.directory)
        try write("dynamic library", at: artifacts.directory.appendingPathComponent("libShared.dylib"))
        try write("shared resource", at: artifacts.directory.appendingPathComponent("Shared_Resources.bundle/message.txt"))
        let output = root.appendingPathComponent("App.app")
        try BundleAssembler(plan: plan, sourceDirectory: root).assemble(artifacts: artifacts, at: output)

        let relocated = root.appendingPathComponent("Relocated.app")
        try FileManager.default.moveItem(at: output, to: relocated)
        try FileManager.default.removeItem(at: artifacts.directory)
        for helper in helpers {
            #expect(FileManager.default.isExecutableFile(atPath: relocated.appendingPathComponent(helper.layout.executablePath).path))
        }
        let framework = relocated.appendingPathComponent("Contents/Helpers/Frameworks/Dynamic.framework")
        #expect(try String(contentsOf: framework.appendingPathComponent("Dynamic"), encoding: .utf8) == "dynamic fixture")
        let current = framework.appendingPathComponent("Versions/Current")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: current.path) == "A")
        let library = relocated.appendingPathComponent("Contents/Helpers/Frameworks/libShared.dylib")
        #expect(try String(contentsOf: library, encoding: .utf8) == "dynamic library")
        let alias = relocated.appendingPathComponent("Contents/Helpers/Shared_Resources.bundle")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == "../Resources/Shared_Resources.bundle")
        #expect(try String(contentsOf: alias.appendingPathComponent("message.txt"), encoding: .utf8) == "shared resource")
        #expect(!FileManager.default.fileExists(atPath: relocated.appendingPathComponent("Contents/Helpers/Resources").path))
    }

    @Test(arguments: [Plan.Resource.bundle(package: "Shared", target: "Resources"),
                      .binaryTarget(name: "Dynamic"), .library(name: "Shared")])
    func duplicateGeneratedDependenciesWithinHelperReject(resource: Plan.Resource) throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try product()
        let helper = try product("Helper", kind: .helperExecutable, resources: [resource, resource])
        let plan = try Plan(target: app.target, app: app, nestedProducts: [helper])
        let artifacts = try artifacts(plan, in: root)
        _ = try framework("Dynamic", in: artifacts.directory)
        try write(at: artifacts.directory.appendingPathComponent("libShared.dylib"))
        try write(at: artifacts.directory.appendingPathComponent("Shared_Resources.bundle/message.txt"))
        let output = root.appendingPathComponent("App.app")
        #expect(throws: (any Error).self) {
            try BundleAssembler(plan: plan, sourceDirectory: root).assemble(artifacts: artifacts, at: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(arguments: ["build/Shared_Resources.bundle", "alternate/Shared_Resources.bundle"],
          ["Shared_Resources.bundle", "shared_resources.bundle", "Shared_Resources.bundle/child"])
    func explicitHelperCopiesCollidingWithGeneratedDependenciesReject(source: String, path: String) throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try product()
        let first = try product("FirstHelper", kind: .helperExecutable,
                                resources: [.bundle(package: "Shared", target: "Resources")])
        let second = try product("SecondHelper", kind: .helperExecutable,
                                 resources: [.copy(.init(source: source, destination: .init(path: path)))])
        let plan = try Plan(target: app.target, app: app, nestedProducts: [first, second])
        let artifacts = try artifacts(plan, in: root)
        try write(at: artifacts.directory.appendingPathComponent("Shared_Resources.bundle/message.txt"))
        try write(at: root.appendingPathComponent("alternate/Shared_Resources.bundle/message.txt"))
        let output = root.appendingPathComponent("App.app")
        #expect(throws: (any Error).self) {
            try BundleAssembler(plan: plan, sourceDirectory: root).assemble(artifacts: artifacts, at: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
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
    @Test(arguments: [BuildConfiguration.debug, .release])
    func generatedSwiftPMAccessorFindsRelocatedResources(configuration: BuildConfiguration) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package")
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "RelocationFixture", platforms: [.macOS("15.0")],
                              products: [.library(name: "ResourceLibrary", type: .dynamic, targets: ["Resources"])],
                              targets: [.target(name: "Resources", resources: [.copy("message.txt")])])
        """, at: package.appendingPathComponent("Dependency/Package.swift"))
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let dependency: Target.Dependency = .product(name: "ResourceLibrary", package: "Dependency")
        let package = Package(name: "Readers", platforms: [.macOS("15.0")], dependencies: [.package(path: "Dependency")],
                              targets: [.executableTarget(name: "Reader", dependencies: [dependency]),
                                        .executableTarget(name: "Service", dependencies: [dependency]),
                                        .executableTarget(name: "Helper", dependencies: [dependency])])
        """
        try write(manifest, at: package.appendingPathComponent("Package.swift"))
        try write("relocated resource", at: package.appendingPathComponent("Dependency/Sources/Resources/message.txt"))
        try write("""
        import Foundation
        public func readResource() throws -> String {
            let file = Bundle.module.url(forResource: "message", withExtension: "txt")!
            return try String(contentsOf: file, encoding: .utf8)
        }
        """, at: package.appendingPathComponent("Dependency/Sources/Resources/Resources.swift"))
        for name in ["Reader", "Service", "Helper"] {
            try write("import Resources\nprint(try readResource())", at: package.appendingPathComponent("Sources/\(name)/main.swift"))
        }
        let resources: [Plan.Resource] = [.bundle(package: "RelocationFixture", target: "Resources"),
                                          .library(name: "ResourceLibrary")]
        var app = try product(resources: resources)
        app.source = .executable(product: "Reader")
        var service = try product("Service", kind: .xpcService, resources: resources)
        service.source = .executable(product: "Service")
        var helper = try product("Helper", kind: .helperExecutable, resources: resources)
        helper.source = .executable(product: "Helper")
        let plan = try Plan(target: app.target, app: app, nestedProducts: [service, helper])
        let settings = try await BuildSettings(configuration: configuration, triple: app.target.triple, buildSystem: .swiftPM,
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
        #expect(try FileManager.default.contentsOfDirectory(atPath: relocated.path) == ["Contents"])
        let alias = relocated.appendingPathComponent("Contents/Helpers/RelocationFixture_Resources.bundle")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path)
                == "../Resources/RelocationFixture_Resources.bundle")
        #expect(!FileManager.default.fileExists(atPath: relocated.appendingPathComponent("Contents/Helpers/Resources").path))
        for product in [helper, service, app] {
            // Disposable local fixture only. Sign inside out, then verify the complete resource seal.
            let library = relocated.appendingPathComponent(product.layout.frameworksPath + "/libResourceLibrary.dylib")
            _ = try run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", library.path])
            let signedPath = relocated.appendingPathComponent(product.layout.bundlePath).path
            _ = try run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", signedPath])
        }
        _ = try run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--verify", "--deep", "--strict", relocated.path])
        for product in plan.allProducts {
            let executable = relocated.appendingPathComponent(product.layout.executablePath)
            #expect(try run(executable) == "relocated resource\n")
        }
    }

    private func run(_ executable: URL, arguments: [String] = []) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return try #require(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
    }
    #endif
}
