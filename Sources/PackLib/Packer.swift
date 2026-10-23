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
                ],
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
            let platformName = buildSettings.triple.contains("simulator") ? "iphonesimulator" : "iphoneos"
            binPath = "out/Products/\(buildSettings.configuration.swiftBuildValue)-\(platformName)"
        }
        let binDir = URL(
            fileURLWithPath: ".build/\(binPath)",
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
                    guard let handle = try? FileHandle(forReadingFrom: src) else {
                        // if we can't find the binary, it might be a static framework that SwiftPM
                        // did not copy into the .build directory. we don't need to pack it anyway.
                        break
                    }
                    defer { try? handle.close() }
                    let isStatic = try Packer.isStaticArchive { offset, count in
                        try handle.seek(toOffset: offset)
                        return try handle.read(upToCount: count) ?? Data()
                    }
                    // static archives are linked into the binary; don't embed them.
                    if !isStatic {
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

    /// Whether a framework binary is a static archive rather than a dynamic library.
    ///
    /// Handles plain archives as well as archives wrapped in a fat (universal) Mach-O header,
    /// which some xcframeworks ship (e.g. GoogleAdsOnDeviceConversion). A fat binary counts as
    /// static only if every slice is an archive.
    ///
    /// - Parameter read: Reads up to `count` bytes at `offset` of the binary.
    static func isStaticArchive(read: (_ offset: UInt64, _ count: Int) throws -> Data) throws -> Bool {
        let header = try read(0, 8)
        if isArchiveMagic(header) { return true }
        guard header.count == 8 else { return false }

        // https://github.com/apple-oss-distributions/cctools/blob/cctools-1010.6/include/mach-o/fat.h
        let entrySize: Int
        switch header.bigEndianUInt32(at: 0) {
        case 0xCAFEBABE: entrySize = 20 // struct fat_arch
        case 0xCAFEBABF: entrySize = 32 // struct fat_arch_64
        default: return false
        }
        // bound the count so a malformed header can't make us read an arbitrary amount
        let archCount = Int(header.bigEndianUInt32(at: 4))
        guard (1...64).contains(archCount) else { return false }

        let table = try read(8, archCount * entrySize)
        guard table.count == archCount * entrySize else { return false }
        for index in 0..<archCount {
            // cputype and cpusubtype (4 bytes each) precede the slice offset
            let offsetPosition = index * entrySize + 8
            let offset = entrySize == 32
                ? table.bigEndianUInt64(at: offsetPosition)
                : UInt64(table.bigEndianUInt32(at: offsetPosition))
            guard isArchiveMagic(try read(offset, 8)) else { return false }
        }
        return true
    }

    // https://github.com/apple/llvm-project/blob/e716ff14c46490d2da6b240806c04e2beef01f40/llvm/include/llvm/Object/Archive.h#L33
    private static func isArchiveMagic(_ bytes: Data) -> Bool {
        bytes == Data("!<arch>\n".utf8) || bytes == Data("!<thin>\n".utf8)
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

extension Data {
    fileprivate func bigEndianUInt32(at offset: Int) -> UInt32 {
        self[(startIndex + offset)..<(startIndex + offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    fileprivate func bigEndianUInt64(at offset: Int) -> UInt64 {
        self[(startIndex + offset)..<(startIndex + offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
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
