import Foundation
import XUtils

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

        let builder = try await buildSettings.swiftPMInvocation(
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
        builder.standardOutput = FileHandle.standardError
        try await builder.runUntilExit()
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
                case .binaryTarget(let name, let frameworkName):
                    let resolvedName = frameworkName ?? findFrameworkName(for: name, in: binDir) ?? name
                    let src = URL(fileURLWithPath: "\(resolvedName).framework/\(resolvedName)", relativeTo: binDir)
                    guard FileManager.default.fileExists(atPath: src.path) else {
                        // if we can't find the binary, it might be a static framework that SwiftPM
                        // did not copy into the .build directory. we don't need to pack it anyway.
                        break
                    }
                    // if the binary is a static archive, don't embed it.
                    // https://github.com/apple/llvm-project/blob/e716ff14c46490d2da6b240806c04e2beef01f40/llvm/include/llvm/Object/Archive.h#L33
                    // swiftlint:disable:previous line_length
                    if !isStaticBinary(at: src) {
                        try await packFile(
                            srcName: "\(resolvedName).framework",
                            dstName: "Frameworks/\(resolvedName).framework",
                            sign: true
                        )
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

private func findFrameworkName(for binaryTargetName: String, in binDir: URL) -> String? {
    let fm = FileManager.default
    guard let contents = try? fm.contentsOfDirectory(atPath: binDir.path) else {
        return nil
    }
    for item in contents where item.hasSuffix(".framework") {
        let frameworkName = String(item.dropLast(".framework".count))
        let binaryPath = binDir
            .appendingPathComponent(item)
            .appendingPathComponent(frameworkName)
        guard fm.fileExists(atPath: binaryPath.path),
              let handle = try? FileHandle(forReadingFrom: binaryPath),
              let data = try? handle.read(upToCount: 256) else {
            continue
        }
        try? handle.close()
        if data.range(of: Data(binaryTargetName.utf8)) != nil {
            return frameworkName
        }
        if frameworkName.hasPrefix(binaryTargetName) || binaryTargetName.hasPrefix(frameworkName) {
            return frameworkName
        }
    }
    return nil
}

private func isStaticBinary(at url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url),
          let bytes = try? handle.read(upToCount: 8) else {
        return false
    }
    defer { try? handle.close() }

    let archMagic = Data("!<arch>\n".utf8)
    let thinMagic = Data("!<thin>\n".utf8)

    if bytes.starts(with: archMagic) || bytes.starts(with: thinMagic) {
        return true
    }

    guard bytes.count >= 4 else { return false }

    let magic = bytes.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    let fatMagic: UInt32 = 0xCAFEBABE
    let fatMagic64: UInt32 = 0xCAFEBABF

    if magic == fatMagic || magic == fatMagic64 {
        let is64 = (magic == fatMagic64)
        try? handle.seek(toOffset: 16)
        guard let offsetData = try? handle.read(upToCount: is64 ? 8 : 4) else { return false }
        let sliceOffset: UInt64 = is64
            ? offsetData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            : UInt64(offsetData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        try? handle.seek(toOffset: sliceOffset)
        guard let sliceMagic = try? handle.read(upToCount: 8) else { return false }
        return sliceMagic.starts(with: archMagic) || sliceMagic.starts(with: thinMagic)
    }

    return false
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
