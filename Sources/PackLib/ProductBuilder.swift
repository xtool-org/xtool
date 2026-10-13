import Foundation
import Dependencies
import XUtils
import Subprocess

/// Compilation owns the generated wrapper package and build tree only.
/// Bundle staging and publication belong exclusively to Packer/BundleAssembler.
public struct ProductBuilder: Sendable {
    public let buildSettings: BuildSettings
    public let plan: Plan

    public init(buildSettings: BuildSettings, plan: Plan) {
        self.buildSettings = buildSettings
        self.plan = plan
    }

    @Dependency(\.productBuildRunner) private var runner

    public func build() async throws -> BuildArtifacts {
        #if os(macOS)
        let hostIsMacOS = true
        #else
        let hostIsMacOS = false
        #endif
        try buildSettings.validateProductBuild(for: plan.target, hostIsMacOS: hostIsMacOS)
        try validateProducts()
        let settings = try buildSettings.withTarget(plan.target)
        let prebuilt = try validatedPrebuiltProducts()
        let sdkArguments = plan.target.platform == .macOS && prebuilt.count != plan.allProducts.count
            ? try await runner.sdkLinkerArguments(settings) : []
        let root = URL(fileURLWithPath: settings.packagePath, isDirectory: true).standardizedFileURL
        let wrapper = root.appendingPathComponent("xtool/.xtool-tmp", isDirectory: true)
        let libraries = plan.allProducts.filter {
            if case .library = $0.resolvedSource { return true }
            return false
        }
        if !libraries.isEmpty { try createWrapper(at: wrapper, root: root, products: libraries, sdkArguments: sdkArguments) }

        // Share one scratch tree so resources and dependency libraries remain
        // beside all products, including mixed direct and wrapped products.
        let scratchOptions = settings.customOptions.contains {
            $0 == "--scratch-path" || $0.hasPrefix("--scratch-path=")
        } ? [] : ["--scratch-path", root.appendingPathComponent(".build").path]
        var directory: URL?
        var executables = prebuilt
        for product in plan.allProducts {
            if prebuilt[product.product] != nil { continue }
            let package: URL
            let name: String
            let options: [String]
            switch product.resolvedSource {
            case .library:
                package = wrapper
                name = product.targetName
                // Planning already resolved root dependencies; avoid dropping
                // its development-only dependencies from Package.resolved.
                options = ["--disable-automatic-resolution"]
            case .executable(let sourceName):
                package = root
                name = sourceName
                options = try directProductOptions(product, in: wrapper, sdkArguments: sdkArguments)
            case .prebuilt:
                continue
            }
            let productSettings = settings.withPackagePath(package.path)
            let arguments = scratchOptions + ["--product", name] + options
            try await runner.build(productSettings, arguments)
            let path = try await runner.binaryPath(productSettings, arguments)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !path.contains("\n"), path.hasPrefix("/") else {
                throw StringError("Build backend returned an invalid binary output path: '\(path)'")
            }
            let binDir = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            if let directory, directory != binDir {
                throw StringError("Build backend produced products in different resource directories")
            }
            directory = binDir
            if let overlay = try SwiftPMResourceAccessor.overlay(for: product, in: binDir, output: wrapper) {
                // SwiftPM regenerates accessors during planning. A compiler overlay adapts only
                // generated target sources, without editing dependencies or racing that regeneration.
                try await runner.build(productSettings, arguments + ["-Xswiftc", "-vfsoverlay", "-Xswiftc", overlay.path])
            }
            let executable = binDir.appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw StringError("Build backend did not produce executable '\(name)' at \(executable.path)")
            }
            executables[product.product] = executable
        }
        let output = directory ?? root
        let staticTargets = try validateBinaryTargets(in: output)
        return BuildArtifacts(directory: output, executables: executables, staticBinaryTargets: staticTargets)
    }

    private func validatedPrebuiltProducts() throws -> [String: URL] {
        var result: [String: URL] = [:]
        for product in plan.allProducts {
            guard case .prebuilt(let path) = product.resolvedSource else { continue }
            let root = URL(fileURLWithPath: buildSettings.packagePath, isDirectory: true)
            let url = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw StringError("Prebuilt executable is missing or not executable: \(url.path)")
            }
            try MachOBinary.validate(url, target: plan.target, executable: true)
            result[product.product] = url
        }
        return result
    }

    private func validateBinaryTargets(in directory: URL) throws -> Set<String> {
        guard plan.target.platform == .macOS else { return [] }
        var staticTargets: Set<String> = []
        for resource in Set(plan.allProducts.flatMap(\.resources)) {
            switch resource {
            case .binaryTarget(let name):
                try ResourceDestination.validateRelativePath(name)
                let framework = directory.appendingPathComponent("\(name).framework/\(name)")
                let archive = directory.appendingPathComponent("lib\(name).a")
                let url = FileManager.default.fileExists(atPath: framework.path) ? framework : archive
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw StringError("Missing binary target '\(name)': expected \(framework.path) or \(archive.path)")
                }
                if try MachOBinary.validate(url, target: plan.target, executable: false) {
                    staticTargets.insert(name)
                } else if url == archive {
                    throw StringError("Binary target '\(name)' is not a static archive: \(url.path)")
                }
            case .library(let name):
                try ResourceDestination.validateRelativePath(name)
                try MachOBinary.validate(directory.appendingPathComponent("lib\(name).dylib"),
                                         target: plan.target, executable: false)
            default: break
            }
        }
        return staticTargets
    }

    private func directProductOptions(
        _ product: Plan.Product, in directory: URL, sdkArguments: [String]
    ) throws -> [String] {
        // SwiftPM forwards CLI -Xlinker options to host macro executables too.
        // SDK toolset options belong only to the target toolchain instead.
        let toolsets = directory.appendingPathComponent("toolsets", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsets, withIntermediateDirectories: true)
        let path = toolsets.appendingPathComponent("\(product.targetName).json")
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": "1.0",
            "swiftCompiler": ["extraCLIOptions": product.linkerArguments + sdkArguments],
        ], options: [.sortedKeys])
        try data.write(to: path)
        return ["--toolset", path.path]
    }

    private func validateProducts() throws {
        let names = plan.allProducts.compactMap { product -> String? in
            switch product.resolvedSource {
            case .library: product.targetName
            case .executable(let name): name
            case .prebuilt: nil
            }
        }
        guard Set(names).count == names.count else {
            throw StringError("Product build output names collide")
        }
        for product in plan.allProducts {
            try product.resolvedSource.validate()
            try ResourceDestination.validateRelativePath(product.product)
            guard !product.product.contains("/") else {
                throw StringError("Product names must not contain path separators")
            }
            switch product.resolvedSource {
            case .prebuilt:
                if product.platform == .macOS && product.type != .helperExecutable
                    && product.resources.contains(where: { if case .bundle = $0 { return true }; return false }) {
                    throw StringError("Prebuilt macOS product '\(product.product)' cannot adapt SwiftPM resource accessors; "
                                      + "build it from source or supply resources with an explicit copy and its own lookup")
                }
            case .executable where buildSettings.buildSystem != .swiftPM:
                throw StringError("Direct executable products currently require the SwiftPM backend")
            case .library(let name), .executable(let name):
                try ResourceDestination.validateRelativePath(name)
                guard !name.contains("/") else {
                    throw StringError("SwiftPM product names must not contain path separators")
                }
            }
        }
    }

    private func createWrapper(
        at directory: URL, root: URL, products: [Plan.Product], sdkArguments: [String]
    ) throws {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let targets = products.map { product in
            let sourceName: String
            if case .library(let name) = product.resolvedSource { sourceName = name } else { sourceName = product.product }
            return """
            .executableTarget(
                name: \(product.targetName.swiftLiteral),
                dependencies: [.product(name: \(sourceName.swiftLiteral), package: "RootPackage")],
                linkerSettings: \(product.linkerSettings(sdkArguments: sdkArguments))
            )
            """
        }.joined(separator: ",\n")
        let platform = plan.target.platform == .macOS ? "macOS" : "iOS"
        let contents = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: \((plan.app.product + "-Builder").swiftLiteral),
            platforms: [.\(platform)(\(plan.target.deploymentTarget.swiftLiteral))],
            dependencies: [.package(name: "RootPackage", path: \(root.path.swiftLiteral))],
            targets: [
                \(targets)
            ]
        )

        """
        try Data(contents.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        for product in products {
            let sources = directory.appendingPathComponent("Sources/\(product.targetName)", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data().write(to: sources.appendingPathComponent("stub.c"))
        }
    }
}

extension String {
    /// Encode untrusted package/product names as a literal, never manifest code.
    fileprivate var swiftLiteral: String { String(reflecting: self) }
}

extension Plan.Product {
    var linkerArguments: [String] {
        var arguments: [String] = []
        if type == .appExtension {
            arguments += ["-Xlinker", "-framework", "-Xlinker", "Foundation",
                          "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]
        }
        for path in runtimeSearchPaths {
            arguments += ["-Xlinker", "-rpath", "-Xlinker", path]
        }
        return arguments
    }

    /// Compute paths from the same frozen layout consumed by assembly.
    var runtimeSearchPaths: [String] {
        let executableDirectory = layout.executablePath.split(separator: "/").dropLast().map(String.init)
        let outer = BundleLayout(platform: platform, kind: .application, name: product).frameworksPath
        let destinations = [outer, layout.frameworksPath]
        var paths: [String] = []
        for destination in destinations {
            let components = destination.split(separator: "/").map(String.init)
            let shared = zip(executableDirectory, components).prefix { $0 == $1 }.count
            let relative = Array(repeating: "..", count: executableDirectory.count - shared) + components.dropFirst(shared)
            let path = (["@executable_path"] + relative).joined(separator: "/")
            if !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    fileprivate func linkerSettings(sdkArguments: [String]) -> String {
        "[.unsafeFlags([\((linkerArguments + sdkArguments).map(\.swiftLiteral).joined(separator: ", "))])]"
    }
}

/// The build backend owns output discovery. Injection lets focused tests assert
/// target/host separation without starting a compiler or provisioning a device.
struct ProductBuildRunner: Sendable {
    var build: @Sendable (BuildSettings, [String]) async throws -> Void
    var binaryPath: @Sendable (BuildSettings, [String]) async throws -> String
    var sdkLinkerArguments: @Sendable (BuildSettings) async throws -> [String] = { try await $0.macOSLinkerArguments() }
}

extension ProductBuildRunner: DependencyKey {
    static let liveValue = Self(
        build: { settings, arguments in
            let invocation = try await settings.swiftPMInvocation(forTool: "build", arguments: arguments)
            try await Subprocess.run(invocation, output: .currentStandardOutput, error: .currentStandardError).checkSuccess()
        },
        binaryPath: { settings, arguments in
            let invocation = try await settings.swiftPMInvocation(forTool: "build", arguments: arguments + ["--show-bin-path"])
            let result = try await Subprocess.run(invocation, output: .string(limit: .max), error: .currentStandardError)
                .checkSuccess()
            return result.standardOutput
        }
    )
}

extension DependencyValues {
    var productBuildRunner: ProductBuildRunner {
        get { self[ProductBuildRunner.self] }
        set { self[ProductBuildRunner.self] = newValue }
    }
}

/// Build outputs are inputs to assembly; the assembler must not invoke SwiftPM.
public struct BuildArtifacts: Sendable {
    public var directory: URL
    public var executables: [String: URL]
    /// Only targets with a present, validated static archive may omit embedding.
    public var staticBinaryTargets: Set<String>

    public init(directory: URL, executables: [String: URL], staticBinaryTargets: Set<String> = []) {
        self.directory = directory
        self.executables = executables
        self.staticBinaryTargets = staticBinaryTargets
    }
}

public struct ProductBuilderClient: Sendable {
    public var build: @Sendable (BuildSettings, Plan) async throws -> BuildArtifacts

    public init(build: @escaping @Sendable (BuildSettings, Plan) async throws -> BuildArtifacts) {
        self.build = build
    }
}

extension ProductBuilderClient: DependencyKey {
    public static let liveValue = Self { settings, plan in
        try await ProductBuilder(buildSettings: settings, plan: plan).build()
    }
}

extension DependencyValues {
    public var productBuilder: ProductBuilderClient {
        get { self[ProductBuilderClient.self] }
        set { self[ProductBuilderClient.self] = newValue }
    }
}

/// A bounded, host-independent reader: Linux must diagnose Apple inputs without
/// relying on the host's `file`, `otool`, or codesign tools.
struct MachOBinary {
    struct Slice {
        var cpu: UInt32
        var fileType: UInt32
        var platform: UInt32?
        var minimumOS: UInt32 = 0
        var sdk: UInt32 = 0
        var installName: String?
        var rpaths: [String] = []
        var hasCodeSignature = false
    }

    @discardableResult
    static func validate(_ url: URL, target: ResolvedTarget, executable: Bool) throws -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw StringError("Missing binary artifact: \(url.path)")
        }
        do {
            let bytes = [UInt8](try Data(contentsOf: url))
            let archive = bytes.starts(with: Array("!<arch>\n".utf8))
            let slices = try inspect(bytes)
            let cpu = try cpuType(for: target.architecture)
            let matching = slices.filter { $0.cpu == cpu }
            guard !matching.isEmpty else { throw StringError("Wrong architecture; expected \(target.architecture)") }
            let platform: UInt32 = switch target.platform {
            case .macOS: 1
            case .iOS: 2
            case .iOSSimulator: 7
            }
            for slice in matching {
                guard slice.platform == platform else {
                    throw StringError("Wrong or missing Mach-O platform; expected \(target.platform.rawValue)")
                }
                guard slice.minimumOS <= packedVersion(target.deploymentTarget) else {
                    throw StringError("Binary minimum OS exceeds deployment target \(target.deploymentTarget)")
                }
                let expectedType: UInt32 = executable ? 2 : (archive ? 1 : 6)
                guard slice.fileType == expectedType else { throw StringError("Wrong Mach-O file type; expected \(expectedType)") }
                if expectedType == 6 {
                    try validateInstallName(slice.installName, binary: url)
                }
            }
            return archive
        } catch {
            throw StringError("Incompatible binary '\(url.path)': \(error)")
        }
    }

    private static func cpuType(for architecture: String) throws -> UInt32 {
        switch architecture {
        case "arm64": return 0x0100000c
        case "x86_64": return 0x01000007
        default: throw StringError("Unsupported architecture: \(architecture)")
        }
    }

    private static func validateInstallName(_ name: String?, binary: URL) throws {
        guard let name, name.hasPrefix("@rpath/") else {
            throw StringError("Dynamic binary must use an @rpath install name for relocation")
        }
        let relative = String(name.dropFirst("@rpath/".count))
        try ResourceDestination.validateRelativePath(relative)
        var base = binary.deletingLastPathComponent()
        if let index = binary.pathComponents.firstIndex(where: { $0.hasSuffix(".framework") }) {
            base = URL(fileURLWithPath: NSString.path(withComponents: Array(binary.pathComponents.prefix(index))),
                       isDirectory: true)
        }
        guard base.appendingPathComponent(relative).resolvingSymlinksInPath() == binary.resolvingSymlinksInPath() else {
            throw StringError("Install name '\(name)' does not resolve to the embedded binary '\(binary.lastPathComponent)'")
        }
    }

    static func packedVersion(_ version: String) -> UInt32 {
        let parts: [UInt32] = version.split(separator: ".").map { UInt32($0) ?? UInt32.max } + [0, 0]
        return (min(parts[0], 65535) << 16) | (min(parts[1], 255) << 8) | min(parts[2], 255)
    }

    static func inspect(_ bytes: [UInt8]) throws -> [Slice] {
        if bytes.starts(with: Array("!<arch>\n".utf8)) { return try archiveSlices(bytes) }
        let magic = try word(bytes, 0)
        if magic == 0xbebafeca || magic == 0xcafebabe {
            let bigEndian = magic == 0xbebafeca
            let count = Int(try word(bytes, 4, bigEndian: bigEndian))
            guard count <= (bytes.count - 8) / 20 else { throw StringError("Truncated universal binary") }
            return try (0..<count).flatMap { index in
                let entry = 8 + index * 20
                let offset = Int(try word(bytes, entry + 8, bigEndian: bigEndian))
                let size = Int(try word(bytes, entry + 12, bigEndian: bigEndian))
                guard offset >= 8 + count * 20, offset <= bytes.count, size <= bytes.count - offset else {
                    throw StringError("Invalid universal binary slice")
                }
                let slices = try inspect(Array(bytes[offset..<(offset + size)]))
                let cpu = try word(bytes, entry, bigEndian: bigEndian)
                guard slices.allSatisfy({ $0.cpu == cpu }) else { throw StringError("Universal binary CPU mismatch") }
                return slices
            }
        }
        guard magic == 0xfeedfacf else { throw StringError("Expected a 64-bit Mach-O binary") }
        return [try thinSlice(bytes)]
    }

    private static func archiveSlices(_ bytes: [UInt8]) throws -> [Slice] {
        var offset = 8
        var slices: [Slice] = []
        while offset < bytes.count {
            guard bytes.count - offset >= 60, bytes[offset + 58] == 0x60, bytes[offset + 59] == 0x0a else {
                throw StringError("Invalid archive member")
            }
            let name = String(decoding: bytes[offset..<(offset + 16)], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let sizeText = String(decoding: bytes[(offset + 48)..<(offset + 58)], as: UTF8.self)
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces)), size >= 0,
                  size <= bytes.count - offset - 60 else { throw StringError("Invalid archive member size") }
            let nameSize = name.hasPrefix("#1/") ? Int(name.dropFirst(3)) : 0
            guard let nameSize, nameSize >= 0, nameSize <= size else { throw StringError("Invalid archive member name") }
            let actualName = nameSize > 0
                ? String(decoding: bytes[(offset + 60)..<(offset + 60 + nameSize)], as: UTF8.self) : name
            if !actualName.hasPrefix("__.SYMDEF") && actualName != "/" && actualName != "//" {
                slices += try inspect(Array(bytes[(offset + 60 + nameSize)..<(offset + 60 + size)]))
            }
            offset += 60 + size + size % 2
        }
        guard !slices.isEmpty else { throw StringError("Archive has no Mach-O object members") }
        return slices
    }

    private static func thinSlice(_ bytes: [UInt8]) throws -> Slice {
        var slice = Slice(cpu: try word(bytes, 4), fileType: try word(bytes, 12))
        let count = Int(try word(bytes, 16))
        let size = Int(try word(bytes, 20))
        guard bytes.count >= 32, size <= bytes.count - 32, count <= size / 8 else {
            throw StringError("Truncated Mach-O load commands")
        }
        var offset = 32
        for _ in 0..<count {
            let command = try word(bytes, offset)
            let length = Int(try word(bytes, offset + 4))
            guard length >= 8, length <= 32 + size - offset else { throw StringError("Invalid Mach-O load command") }
            let load = Array(bytes[offset..<(offset + length)])
            switch command {
            case 0x32: // LC_BUILD_VERSION
                guard slice.platform == nil else { throw StringError("Duplicate Mach-O platform metadata") }
                slice.platform = try word(load, 8)
                slice.minimumOS = try word(load, 12)
                slice.sdk = try word(load, 16)
            case 0x24, 0x25: // legacy LC_VERSION_MIN_MACOSX / IPHONEOS
                guard slice.platform == nil else { throw StringError("Duplicate Mach-O platform metadata") }
                slice.platform = command == 0x24 ? 1 : 2
                slice.minimumOS = try word(load, 8)
                slice.sdk = try word(load, 12)
            case 0xd: slice.installName = try loadString(load)
            case 0x8000001c: slice.rpaths.append(try loadString(load))
            case 0x1d: slice.hasCodeSignature = true
            default: break
            }
            offset += length
        }
        guard offset == 32 + size else { throw StringError("Inconsistent Mach-O command size") }
        return slice
    }

    private static func loadString(_ load: [UInt8]) throws -> String {
        let offset = Int(try word(load, 8))
        guard offset >= 12, offset < load.count, let end = load[offset...].firstIndex(of: 0) else {
            throw StringError("Invalid Mach-O load-command string")
        }
        return String(decoding: load[offset..<end], as: UTF8.self)
    }

    private static func word(_ bytes: [UInt8], _ offset: Int, bigEndian: Bool = false) throws -> UInt32 {
        guard offset >= 0, offset <= bytes.count, bytes.count - offset >= 4 else { throw StringError("Truncated Mach-O data") }
        return (0..<4).reduce(UInt32(0)) { value, index in
            value | (UInt32(bytes[offset + index]) << ((bigEndian ? 3 - index : index) * 8))
        }
    }
}
