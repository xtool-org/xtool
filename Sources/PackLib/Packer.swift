import Foundation
import XUtils
import Subprocess

public struct Packer: Sendable {
    public let buildSettings: BuildSettings
    public let plan: Plan

    public init(buildSettings: BuildSettings, plan: Plan) {
        self.plan = plan
        self.buildSettings = buildSettings
    }

    private func build() async throws {
        let xtoolDir = URL(fileURLWithPath: "xtool")
        let packageDir = xtoolDir.appendingPathComponent(".xtool-tmp")
        try? FileManager.default.removeItem(at: packageDir)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)

        if URL(fileURLWithPath: "Packages").dirExists {
            try FileManager.default.createSymbolicLink(
                atPath: packageDir.appendingPathComponent("Packages").path,
                withDestinationPath: "../../Packages"
            )
        }

        let packageSwift = packageDir.appendingPathComponent("Package.swift")
        let contents = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "\(plan.app.product)-Builder",
            platforms: [
                .iOS("\(plan.app.deploymentTarget)"),
            ],
            dependencies: [
                .package(name: "RootPackage", path: "../.."),
            ],
            targets: [
                \(
                    plan.allProducts.map {
                        """
                        .executableTarget(
                            name: "\($0.targetName)",
                            dependencies: [
                                .product(name: "\($0.product)", package: "RootPackage"),
                            ],
                            linkerSettings: \($0.linkerSettings)
                        )
                        """
                    }
                    .joined(separator: ",\n")
                )
            ]
        )\n
        """
        try Data(contents.utf8).write(to: packageSwift)

        var constValuesOptions: [String] = []
        if buildSettings.buildSystem == .swiftPM {
            // Swift Build emits const values for App Intents by itself, SwiftPM's native build doesn't.
            // The list goes to the frontend directly since the driver's -const-gather-protocols-list
            // only exists as of Swift 6.4
            let protocolsFile = URL(fileURLWithPath: packageDir.appendingPathComponent("const-protocols.json").path)
            try JSONEncoder().encode(AppIntentsMetadata.constValueProtocols).write(to: protocolsFile)
            constValuesOptions = [
                "-emit-const-values",
                "-Xfrontend", "-const-gather-protocols-file",
                "-Xfrontend", protocolsFile.path,
            ].flatMap { ["-Xswiftc", $0] }
        }

        for product in plan.allProducts {
            let sources: URL = packageDir.appendingPathComponent("Sources/\(product.targetName)", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data().write(to: sources.appendingPathComponent("stub.c", isDirectory: false))
        }

        let buildConfig = try await buildSettings
            .withPackagePath(packageDir.path)
            .swiftPMInvocation(
                forTool: "build",
                arguments: [
                    "--scratch-path", ".build",
                    // resolving can cause SwiftPM to overwrite the root package deps
                    // with just the deps needed for the builder package (which is to
                    // say, any "dev dependencies" of the root package may be removed.)
                    // fortunately we've already resolved the root package by this point
                    // in order to dump the plan, so we can skip resolution here to skirt
                    // the issue.
                    "--disable-automatic-resolution",
                ] + constValuesOptions,
            )
        try await Subprocess.run(
            buildConfig,
            output: .currentStandardOutput,
            error: .currentStandardError,
        )
        .checkSuccess()
    }

    public func pack() async throws -> URL {
        try await build()

        let output = try TemporaryDirectory(name: "\(plan.app.product).app")

        let outputURL = output.url

        let binPath: String
        switch buildSettings.buildSystem {
        case .swiftPM:
            binPath = "\(buildSettings.triple)/\(buildSettings.configuration.rawValue)"
        case .swiftBuild:
            binPath = "out/Products/\(swiftBuildConfigurationDirectory)"
        }
        let binDir = URL(
            fileURLWithPath: ".build/\(binPath)",
            isDirectory: true
        )

        var bundleIDsByModule: [String: [String]] = [:]
        for product in plan.allProducts {
            for module in product.modules {
                bundleIDsByModule[Self.moduleName(module), default: []].append(product.bundleID)
            }
        }
        let sharedBundleIDs = bundleIDsByModule.filter { $1.count > 1 }.mapValues { $0.sorted() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for product in plan.allProducts {
                try pack(
                    product: product,
                    binDir: binDir,
                    outputURL: product.directory(inApp: outputURL),
                    sharedBundleIDs: sharedBundleIDs,
                    &group
                )
            }

            while !group.isEmpty {
                do {
                    try await group.next()
                } catch is CancellationError {
                    // continue
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        }

        let dest = URL(fileURLWithPath: "xtool").appendingPathComponent(outputURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try output.persist(at: dest)
        return dest
    }

    @Sendable private func pack(
        product: Plan.Product,
        binDir: URL,
        outputURL: URL,
        sharedBundleIDs: [String: [String]],
        _ group: inout ThrowingTaskGroup<Void, Error>
    ) throws {
        @Sendable func packFileToRoot(srcName: String) async throws {
            let srcURL = URL(fileURLWithPath: srcName)
            let destURL = outputURL.appendingPathComponent(srcURL.lastPathComponent)
            try FileManager.default.copyItem(at: srcURL, to: destURL)

            try Task.checkCancellation()
        }

        @Sendable func packFile(srcName: String, dstName: String? = nil, sign: Bool = false) async throws {
            let srcURL = URL(fileURLWithPath: srcName, relativeTo: binDir)
            let dstURL = URL(fileURLWithPath: dstName ?? srcURL.lastPathComponent, relativeTo: outputURL)
            try? FileManager.default.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: srcURL, to: dstURL)

            try Task.checkCancellation()
        }

        // Ensure output directory is available
        try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        for command in product.resources {
            group.addTask {
                switch command {
                case .bundle(let package, let target):
                    try await packFile(srcName: "\(package)_\(target).bundle")
                case .binaryTarget(let name):
                    let src = URL(fileURLWithPath: "\(name).framework/\(name)", relativeTo: binDir)
                    let magic = Data("!<arch>\n".utf8)
                    let thinMagic = Data("!<thin>\n".utf8)
                    guard let bytes = try? FileHandle(forReadingFrom: src).read(upToCount: magic.count) else {
                        // if we can't find the binary, it might be a static framework that SwiftPM
                        // did not copy into the .build directory. we don't need to pack it anyway.
                        break
                    }
                    // if the magic matches one of these it's a static archive; don't embed it.
                    // https://github.com/apple/llvm-project/blob/e716ff14c46490d2da6b240806c04e2beef01f40/llvm/include/llvm/Object/Archive.h#L33
                    // swiftlint:disable:previous line_length
                    if bytes != magic && bytes != thinMagic {
                        try await packFile(srcName: "\(name).framework", dstName: "Frameworks/\(name).framework", sign: true)
                    }
                case .library(let name):
                    try await packFile(srcName: "lib\(name).dylib", dstName: "Frameworks/lib\(name).dylib", sign: true)
                case .root(let source):
                    try await packFileToRoot(srcName: source)
                }
            }
        }
        if let iconPath = product.iconPath {
            group.addTask {
                try await packFileToRoot(srcName: iconPath)
            }
        }
        group.addTask {
            try writeAppIntentsMetadata(product: product, sharedBundleIDs: sharedBundleIDs, outputURL: outputURL)
        }
        group.addTask {
            try await packFile(srcName: product.targetName, dstName: product.product)
        }
        group.addTask {
            var info = product.infoPlist

            if product.type == .application {
                info["UIRequiredDeviceCapabilities"] = ["arm64"]
                info["LSRequiresIPhoneOS"] = true
                info["CFBundleSupportedPlatforms"] = Packer.cfBundleSupportedPlatforms(for: buildSettings.triple)
            }

            if let iconPath = product.iconPath {
                let iconName = URL(fileURLWithPath: iconPath).deletingPathExtension().lastPathComponent
                info["CFBundleIconFile"] = iconName
            }

            let infoPath = outputURL.appendingPathComponent("Info.plist")
            let encodedPlist = try PropertyListSerialization.data(
                fromPropertyList: info,
                format: .xml,
                options: 0
            )
            try encodedPlist.write(to: infoPath)
        }
    }

    private var swiftBuildConfigurationDirectory: String {
        let platformName = buildSettings.triple.contains("simulator") ? "iphonesimulator" : "iphoneos"
        return "\(buildSettings.configuration.swiftBuildValue)-\(platformName)"
    }

    // SwiftPM uses a module's c99name for its directory and its type names
    private static func moduleName(_ target: String) -> String {
        String(target.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }

    @Sendable private func writeAppIntentsMetadata(
        product: Plan.Product,
        sharedBundleIDs: [String: [String]],
        outputURL: URL
    ) throws {
        // an index among the resources takes precedence
        let hasOwnMetadata = product.resources.contains {
            if case .root(let source) = $0 {
                URL(fileURLWithPath: source).lastPathComponent == "Metadata.appintents"
            } else {
                false
            }
        }
        if hasOwnMetadata { return }

        let decoder = JSONDecoder()
        var entries: [JSONValue] = []
        for module in product.modules {
            for file in constValuesFiles(target: module) {
                entries += try decoder.decode([JSONValue].self, from: Data(contentsOf: file))
            }
        }
        let files: [String: Data]?
        do {
            files = try AppIntentsMetadata(entries: entries, sharedBundleIDs: sharedBundleIDs).files()
        } catch let error as AppIntentsMetadata.Unsupported {
            print("warning: Skipping the App Intents metadata of \(product.product): \(error)")
            return
        }
        guard let files else { return }
        let directory = outputURL.appendingPathComponent("Metadata.appintents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in files {
            try data.write(to: directory.appendingPathComponent(name))
        }
    }

    private func constValuesFiles(target: String) -> [URL] {
        func contents(_ url: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        }
        switch buildSettings.buildSystem {
        case .swiftPM:
            // one file per module
            let directory = URL(fileURLWithPath: ".build", isDirectory: true)
                .appendingPathComponent("\(buildSettings.triple)/\(buildSettings.configuration.rawValue)", isDirectory: true)
                .appendingPathComponent("\(Self.moduleName(target)).build", isDirectory: true)
            return contents(directory).filter { $0.pathExtension == "swiftconstvalues" }
        case .swiftBuild:
            // one file per source file. The output file map only lists current sources,
            // unlike the directory, which keeps the files of deleted ones
            let arch = buildSettings.triple.split(separator: "-").first.map(String.init) ?? "arm64"
            let intermediates = URL(fileURLWithPath: ".build/out/Intermediates.noindex", isDirectory: true)
            var files: [URL] = []
            for package in contents(intermediates) where package.pathExtension == "build" {
                let objects = package.appendingPathComponent(
                    "\(swiftBuildConfigurationDirectory)/\(target)-t.build/Objects-normal/\(arch)",
                    isDirectory: true
                )
                for map in contents(objects) where map.lastPathComponent.hasSuffix("-OutputFileMap.json") {
                    guard let data = try? Data(contentsOf: map),
                          let outputs = try? JSONDecoder().decode([String: [String: String]].self, from: data)
                    else { continue }
                    files += outputs.values.compactMap { $0["const-values"] }
                        .filter { FileManager.default.fileExists(atPath: $0) }
                        .map { URL(fileURLWithPath: $0) }
                }
            }
            return files
        }
    }

    static func cfBundleSupportedPlatforms(for triple: String) -> [String] {
        let components = triple.split(separator: "-").map(String.init)
        guard let appleIndex = components.firstIndex(of: "apple"),
              components.indices.contains(appleIndex + 1) else {
            return ["iPhoneOS"]
        }

        let os = components[appleIndex + 1].prefix { !$0.isNumber }
        switch os {
        case "ios" where components.contains("simulator"):
            return ["iPhoneSimulator"]
        case "ios":
            return ["iPhoneOS"]
        case "macos", "macosx":
            return ["MacOSX"]
        default:
            return ["iPhoneOS"]
        }
    }
}

extension Plan.Product {
    fileprivate var linkerSettings: String {
        switch self.type {
        case .application: """
        [
            .unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
            ]),
        ]
        """
        case .appExtension: """
        [
            // Link to Foundation framework which implements the _NSExtensionMain entrypoint
            .linkedFramework("Foundation"),
            .unsafeFlags([
                // Set the entry point to Foundation`_NSExtensionMain
                "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                // Include frameworks that the host app may use
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../Frameworks",
                // ...as well as our own
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
            ]),
        ]
        """
        }
    }
}
