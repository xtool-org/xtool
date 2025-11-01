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

        for product in plan.allProducts {
            let sources: URL = packageDir.appendingPathComponent("Sources/\(product.targetName)", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data().write(to: sources.appendingPathComponent("stub.c", isDirectory: false))
        }

        let buildConfig = try await buildSettings.swiftPMInvocation(
            forTool: "build",
            arguments: [
                "--package-path", packageDir.path,
                "--scratch-path", ".build",
                // resolving can cause SwiftPM to overwrite the root package deps
                // with just the deps needed for the builder package (which is to
                // say, any "dev dependencies" of the root package may be removed.)
                // fortunately we've already resolved the root package by this point
                // in order to dump the plan, so we can skip resolution here to skirt
                // the issue.
                "--disable-automatic-resolution",
            ]
        )
        try await Subprocess.run(
            buildConfig,
            output: .standardError
        )
        .checkSuccess()
    }

    public func pack() async throws -> URL {
        try await build()

        let output = try TemporaryDirectory(name: "\(plan.app.product).app")

        let outputURL = output.url

        let binDir = URL(
            fileURLWithPath: ".build/\(buildSettings.triple)/\(buildSettings.configuration.rawValue)",
            isDirectory: true
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for product in plan.allProducts {
                try pack(
                    product: product,
                    binDir: binDir,
                    outputURL: product.directory(inApp: outputURL),
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
            try await packFile(srcName: product.targetName, dstName: product.product)
        }
        group.addTask {
            var info = product.infoPlist

            if product.type == .application {
                info["UIRequiredDeviceCapabilities"] = ["arm64"]
                info["LSRequiresIPhoneOS"] = true
                info["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
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
