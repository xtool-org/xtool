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

        let builds = try invocations(settings: settings, root: root, wrapper: wrapper, prebuilt: prebuilt,
                                     sdkArguments: sdkArguments)

        // SwiftPM regenerates accessors during planning. A compiler overlay adapts only generated
        // target sources, without editing dependencies or racing that regeneration. Every build
        // passes the same overlay path, so flags never change and no-op rebuilds stay no-ops.
        // The overlay covers the accessors of the previous build. When accessors are missing, as on
        // a clean build, a plan-only run generates them without compiling, so each module compiles
        // once; a later pass recompiles any accessor that the overlay still did not adapt.
        let built = builds.map(\.product)
        let overlay = try await initialOverlay(for: builds, wrapper: wrapper)
        let overlayArguments = overlay.map { ["-Xswiftc", "-vfsoverlay", "-Xswiftc", $0.url.path] } ?? []

        var directory: URL?
        var executables = prebuilt
        for build in builds {
            let arguments = build.arguments + overlayArguments
            try await runner.build(build.settings, arguments)
            let binDir = try await binaryDirectory(build.settings, arguments)
            if let directory, directory != binDir {
                throw StringError("Build backend produced products in different resource directories")
            }
            directory = binDir
            let executable = binDir.appendingPathComponent(build.name)
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw StringError("Build backend did not produce executable '\(build.name)' at \(executable.path)")
            }
            executables[build.product.product] = executable
        }
        if let directory, let overlay,
           let final = try SwiftPMResourceAccessor.overlay(for: built, in: directory, output: wrapper) {
            // An accessor the build's overlay did not cover compiled unadapted, even if its adapted
            // copy is unchanged from an earlier build.
            let stale = Set(final.changedSources + final.sources.filter { !overlay.sources.contains($0) })
            if !stale.isEmpty {
                // Touching the generated sources makes the backend recompile exactly those modules
                // (and their dependents) with the now-current adaptation; the flags stay unchanged.
                for source in stale {
                    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: source.path)
                }
                for build in builds {
                    try await runner.build(build.settings, build.arguments + overlayArguments)
                }
                let settled = try SwiftPMResourceAccessor.overlay(for: built, in: directory, output: wrapper)
                guard settled?.changedSources.isEmpty != false else {
                    throw StringError("Generated SwiftPM resource accessors changed during the build")
                }
            }
        }
        let output = directory ?? root
        let staticTargets = try validateBinaryTargets(in: output)
        return BuildArtifacts(directory: output, executables: executables, staticBinaryTargets: staticTargets)
    }

    private typealias Invocation = (product: Plan.Product, name: String, settings: BuildSettings, arguments: [String])

    private func initialOverlay(for builds: [Invocation], wrapper: URL) async throws -> SwiftPMResourceAccessor.Overlay? {
        let built = builds.map(\.product)
        guard let first = builds.first, !SwiftPMResourceAccessor.bundleNames(for: built).isEmpty else { return nil }
        let directory = try await binaryDirectory(first.settings, first.arguments)
        let overlay = try SwiftPMResourceAccessor.overlay(for: built, in: directory, output: wrapper, requireAll: false)
        guard let overlay, !overlay.complete else { return overlay }
        let arguments = ["-Xswiftc", "-vfsoverlay", "-Xswiftc", overlay.url.path]
        for build in builds { try await runner.plan(build.settings, build.arguments + arguments) }
        return try SwiftPMResourceAccessor.overlay(for: built, in: directory, output: wrapper, requireAll: false)
    }

    private func invocations(
        settings: BuildSettings, root: URL, wrapper: URL, prebuilt: [String: URL], sdkArguments: [String]
    ) throws -> [Invocation] {
        // Share one scratch tree so resources and dependency libraries remain
        // beside all products, including mixed direct and wrapped products.
        let scratchOptions = settings.customOptions.contains {
            $0 == "--scratch-path" || $0.hasPrefix("--scratch-path=")
        } ? [] : ["--scratch-path", root.appendingPathComponent(".build").path]
        var builds: [Invocation] = []
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
                options = try toolsetOptions(name: product.targetName,
                                             linkerOptions: Self.linkerOptions(product.linkerArguments + sdkArguments),
                                             in: wrapper)
            case .prebuilt:
                continue
            }
            builds.append((product, name, settings.withPackagePath(package.path), scratchOptions + ["--product", name] + options))
        }
        return builds
    }

    private func binaryDirectory(_ settings: BuildSettings, _ arguments: [String]) async throws -> URL {
        let path = try await runner.binaryPath(settings, arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains("\n"), path.hasPrefix("/") else {
            throw StringError("Build backend returned an invalid binary output path: '\(path)'")
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
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
            case .binaryTarget(let name, let xcframework):
                try ResourceDestination.validateRelativePath(name)
                let framework = directory.appendingPathComponent("\(name).framework/\(name)")
                let archive = Self.staticArchive(forBinaryTarget: name, xcframework: xcframework,
                                                 in: directory, target: plan.target)
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

    private struct XCFrameworkInfo: Decodable {
        struct Library: Decodable {
            let LibraryPath: String
            let SupportedPlatform: String
            let SupportedPlatformVariant: String?
            let SupportedArchitectures: [String]
        }

        let AvailableLibraries: [Library]
    }

    /// SwiftPM copies a static xcframework slice into the bin directory under the slice's own
    /// `LibraryPath`, which need not match the target name. Local binary targets name their
    /// XCFramework; remote and archived ones are extracted to `<scratch>/artifacts/<package>/<target>/`.
    /// Otherwise expect `lib<name>.a`.
    static func staticArchive(
        forBinaryTarget name: String, xcframework: String? = nil, in directory: URL, target: ResolvedTarget
    ) -> URL {
        let manager = FileManager.default
        let artifacts = directory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts", isDirectory: true)
        let variant: String? = target.platform == .iOSSimulator ? "simulator" : nil
        var candidates = xcframework.map { [URL(fileURLWithPath: $0, isDirectory: true)] } ?? []
        for package in (try? manager.contentsOfDirectory(atPath: artifacts.path).sorted()) ?? [] {
            let targetDirectory = artifacts.appendingPathComponent(package).appendingPathComponent(name)
            let entries = (try? manager.contentsOfDirectory(atPath: targetDirectory.path).sorted()) ?? []
            candidates += entries.filter { $0.hasSuffix(".xcframework") }.map { targetDirectory.appendingPathComponent($0) }
        }
        for candidate in candidates {
            let plist = candidate.appendingPathComponent("Info.plist")
            guard let data = try? Data(contentsOf: plist),
                  let info = try? PropertyListDecoder().decode(XCFrameworkInfo.self, from: data),
                  let library = info.AvailableLibraries.first(where: {
                      $0.SupportedPlatform == target.platform.packagePlatformName
                          && $0.SupportedPlatformVariant == variant
                          && $0.SupportedArchitectures.contains(target.architecture)
                  }),
                  library.LibraryPath.hasSuffix(".a"),
                  (try? ResourceDestination.validateComponent(library.LibraryPath, "Library path")) != nil else { continue }
            return directory.appendingPathComponent(library.LibraryPath)
        }
        return directory.appendingPathComponent("lib\(name).a")
    }

    private func toolsetOptions(name: String, linkerOptions: [String], in directory: URL) throws -> [String] {
        // SwiftPM forwards CLI -Xlinker options to host macro executables too.
        // SDK toolset options belong only to the target toolchain instead.
        // Compiler options are deliberately absent: a toolset applies to every module, and each
        // package must compile for its own platform minimum, as with `swift build` and Xcode.
        // Dependencies such as swift-perception declare backports `obsoleted:` at newer releases.
        // The product's deployment target reaches the binary through `-platform_version` here.
        guard !linkerOptions.isEmpty else { return [] }
        let toolsets = directory.appendingPathComponent("toolsets", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsets, withIntermediateDirectories: true)
        let path = toolsets.appendingPathComponent("\(name).json")
        let toolset: [String: Any] = ["schemaVersion": "1.0", "linker": ["extraCLIOptions": linkerOptions]]
        let data = try JSONSerialization.data(withJSONObject: toolset, options: [.sortedKeys])
        try data.writeIfChanged(to: path)
        return ["--toolset", path.path]
    }

    /// Toolset linker options reach the linker directly; drop the compiler driver's `-Xlinker` prefixes.
    static func linkerOptions(_ arguments: [String]) -> [String] {
        stride(from: 0, to: arguments.count, by: 2).map { index in
            precondition(arguments[index] == "-Xlinker" && index + 1 < arguments.count, "Expected -Xlinker pairs")
            return arguments[index + 1]
        }
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
            try ResourceDestination.validateComponent(product.product, "Product name")
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
                try ResourceDestination.validateComponent(name, "SwiftPM product name")
            }
        }
    }

    private func createWrapper(
        at directory: URL, root: URL, products: [Plan.Product], sdkArguments: [String]
    ) throws {
        // Keep unchanged files untouched: new timestamps would relink every product, and the
        // directory also holds the resource-accessor overlay of the previous build.
        let sourcesDirectory = directory.appendingPathComponent("Sources", isDirectory: true)
        let stale = Set((try? FileManager.default.contentsOfDirectory(atPath: sourcesDirectory.path)) ?? [])
            .subtracting(products.map(\.targetName))
        for name in stale { try FileManager.default.removeItem(at: sourcesDirectory.appendingPathComponent(name)) }
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
        try Data(contents.utf8).writeIfChanged(to: directory.appendingPathComponent("Package.swift"))
        for product in products {
            let sources = sourcesDirectory.appendingPathComponent(product.targetName, isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data().writeIfChanged(to: sources.appendingPathComponent("stub.c"))
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
    /// Plans a build without compiling; SwiftPM writes generated sources such as resource accessors while planning.
    var plan: @Sendable (BuildSettings, [String]) async throws -> Void = { _, _ in }
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
        },
        plan: { settings, arguments in
            let invocation = try await settings.swiftPMInvocation(forTool: "build",
                                                                  arguments: arguments + ["--print-manifest-job-graph"])
            try await Subprocess.run(invocation, output: .discarded, error: .currentStandardError).checkSuccess()
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
        /// Object files from a static archive, including archives inside a universal binary.
        var archiveMember = false
        struct Dependency {
            var path: String
            var weak: Bool
        }
        var dependencies: [Dependency] = []

        mutating func read(command: UInt32, load: [UInt8]) throws {
            switch command {
            case 0x32: // LC_BUILD_VERSION
                guard platform == nil else { throw StringError("Duplicate Mach-O platform metadata") }
                platform = try MachOBinary.word(load, 8)
                minimumOS = try MachOBinary.word(load, 12)
                sdk = try MachOBinary.word(load, 16)
            case 0x24, 0x25: // legacy LC_VERSION_MIN_MACOSX / IPHONEOS
                guard platform == nil else { throw StringError("Duplicate Mach-O platform metadata") }
                platform = command == 0x24 ? 1 : 2
                minimumOS = try MachOBinary.word(load, 8)
                sdk = try MachOBinary.word(load, 12)
            case 0xd: installName = try MachOBinary.loadString(load)
            case 0xc, 0x80000018, 0x8000001f, 0x80000023:
                dependencies.append(.init(path: try MachOBinary.loadString(load), weak: command == 0x80000018))
            case 0x8000001c: rpaths.append(try MachOBinary.loadString(load))
            case 0x1d: hasCodeSignature = true
            default: break
            }
        }
    }

    @discardableResult
    static func validate(_ url: URL, target: ResolvedTarget, executable: Bool) throws -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw StringError("Missing binary artifact: \(url.path)")
        }
        do {
            let slices = try inspect([UInt8](try Data(contentsOf: url)))
            let cpu = try cpuType(for: target.architecture)
            let matching = slices.filter { $0.cpu == cpu }
            guard !matching.isEmpty else { throw StringError("Wrong architecture; expected \(target.architecture)") }
            let archive = matching.allSatisfy(\.archiveMember)
            let platform = platformType(for: target.platform)
            for slice in matching {
                guard slice.platform == platform else {
                    throw StringError("Wrong or missing Mach-O platform; expected \(target.platform.rawValue)")
                }
                guard slice.minimumOS <= packedVersion(target.deploymentTarget) else {
                    throw StringError("Binary minimum OS exceeds deployment target \(target.deploymentTarget)")
                }
                let expectedType: UInt32 = executable ? 2 : (slice.archiveMember ? 1 : 6)
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

    static func platformType(for platform: TargetPlatform) -> UInt32 {
        switch platform {
        case .macOS: 1
        case .iOS: 2
        case .iOSSimulator: 7
        }
    }

    static func cpuType(for architecture: String) throws -> UInt32 {
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
                slices += try inspect(Array(bytes[(offset + 60 + nameSize)..<(offset + 60 + size)])).map {
                    var member = $0
                    member.archiveMember = true
                    return member
                }
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
            try slice.read(command: command, load: load)
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
