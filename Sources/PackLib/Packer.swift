import Foundation

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

        let packageSwift = packageDir.appendingPathComponent("Package.swift")
        let contents = """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "\(plan.product)-Builder",
                platforms: [
                    .iOS("\(plan.deploymentTarget)"),
                ],
                dependencies: [
                    .package(name: "RootPackage", path: "../.."),
                ],
                targets: [
                    \(
                        plan.extensions.map {
                            """
                            .executableTarget(
                                name: "\($0.product)-Extension",
                                dependencies: [
                                    .product(name: "\($0.product)", package: "RootPackage"),
                                ]
                            ),
                            """
                        }
                    )
                    .executableTarget(
                        name: "\(plan.product)-App",
                        dependencies: [
                            .product(name: "\(plan.product)", package: "RootPackage"),
                        ]
                    ),
                ]
            )\n
            """
        try Data(contents.utf8).write(to: packageSwift)

        func writeStubs(name: String) throws {
            let sources = packageDir.appending(components: "Sources", name, directoryHint: .isDirectory)
            print("about to write stubs in \(sources)")
            try? FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data().write(to: sources.appending(component: "stub.c", directoryHint: .notDirectory))
        }

        try writeStubs(name: "\(plan.product)-App")

        let builder = try await buildSettings.swiftPMBuild(packageDir: packageDir.path, product: "\(plan.product)-App")
        builder.standardOutput = FileHandle.standardError
        try await builder.runUntilExit()

        for ext in plan.extensions {
            try writeStubs(name: "\(ext.product)-Extension")
            let builder = try await buildSettings.swiftPMBuild(packageDir: packageDir.path, product: "\(ext.product)-Extension")
            builder.standardOutput = FileHandle.standardError
            try await builder.runUntilExit()
        }
    }

    public func pack() async throws -> URL {
        try await build()

        let output = try TemporaryDirectory(name: "\(plan.product).app")

        let binDir = URL(
            fileURLWithPath: ".build/\(buildSettings.triple)/\(buildSettings.configuration.rawValue)",
            isDirectory: true
        )

        let outputDir = output.url

        try await withThrowingTaskGroup(of: Void.self) { group in
            _pack(
                product: plan.base, 
                isExtension: false, 
                binDir: binDir,
                outputDir: outputDir,
                &group
            )

            for ext in plan.extensions {
                _pack(
                    product: ext, 
                    isExtension: true,
                    binDir: binDir,
                    outputDir: outputDir.appending(components: "PlugIns/\(ext.product).appex"),
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

        let dest = URL(fileURLWithPath: "xtool").appendingPathComponent(output.url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try output.persist(at: dest)
        return dest
    }

    @Sendable private func _pack(
        product: Plan.Product,
        isExtension: Bool,
        binDir: URL,
        outputDir: URL,
        _ group: inout ThrowingTaskGroup<Void, Error>
    ) {
        @Sendable func packFileToRoot(srcName: String) async throws {
            let srcURL = URL(fileURLWithPath: srcName)
            let destURL = outputDir.appendingPathComponent(srcURL.lastPathComponent)
            try FileManager.default.copyItem(at: srcURL, to: destURL)

            try Task.checkCancellation()
        }

        @Sendable func packFile(srcName: String, dstName: String? = nil, sign: Bool = false) async throws {
            let srcURL = URL(fileURLWithPath: srcName, relativeTo: binDir)
            let dstURL = URL(fileURLWithPath: dstName ?? srcURL.lastPathComponent, relativeTo: outputDir)
            try? FileManager.default.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: srcURL, to: dstURL)

            try Task.checkCancellation()
        }

        for command in plan.resources {
            group.addTask {
                switch command {
                case .bundle(let package, let target):
                    try await packFile(srcName: "\(package)_\(target).bundle")
                case .binaryTarget(let name):
                    let src = URL(fileURLWithPath: "\(name).framework/\(name)", relativeTo: binDir)
                    let magic = Data("!<arch>\n".utf8)
                    let thinMagic = Data("!<thin>\n".utf8)
                    let bytes = try FileHandle(forReadingFrom: src).read(upToCount: magic.count)
                    // if the magic matches one of these it's a static archive; don't embed it.
                    // https://github.com/apple/llvm-project/blob/e716ff14c46490d2da6b240806c04e2beef01f40/llvm/include/llvm/Object/Archive.h#L33
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
        if let iconPath = plan.iconPath {
            group.addTask {
                try await packFileToRoot(srcName: iconPath)
            }
        }
        group.addTask {
            try await packFile(srcName: "\(plan.product)-\(!isExtension ? "App" : "Extension")", dstName: plan.product)
        }
        group.addTask {
            var info = plan.infoPlist

            if let iconPath = plan.iconPath {
                let iconName = URL(fileURLWithPath: iconPath).deletingPathExtension().lastPathComponent
                info["CFBundleIconFile"] = iconName
            }

            let infoPath = outputDir.appendingPathComponent("Info.plist")
            let encodedPlist = try PropertyListSerialization.data(
                fromPropertyList: info,
                format: .xml,
                options: 0
            )
            try encodedPlist.write(to: infoPath)
        }
    }
}

private extension BuildSettings {
    func swiftPMBuild(packageDir: String, product: String) async throws -> Process {
        try await swiftPMInvocation(
            forTool: "build",
            arguments: [
                "--package-path", packageDir,
                "--scratch-path", ".build",
                "--product", product,
                // resolving can cause SwiftPM to overwrite the root package deps
                // with just the deps needed for the builder package (which is to
                // say, any "dev dependencies" of the root package may be removed.)
                // fortunately we've already resolved the root package by this point
                // in order to dump the plan, so we can skip resolution here to skirt
                // the issue.
                "--disable-automatic-resolution",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
            ]
        )
    }
}