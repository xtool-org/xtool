import Foundation
import ArgumentParser
import PackLib
import XKit
import Dependencies
import XUtils

struct PackOperation {
    struct BuildOptions: ParsableArguments {
        @Option(
            name: .shortAndLong,
            help: "Build with configuration"
        ) var configuration: BuildConfiguration = .debug

        init() {}

        init(configuration: BuildConfiguration) {
            self.configuration = configuration
        }
    }

    static let defaultTriple = "arm64-apple-ios"

    var triple: String?
    var buildOptions = BuildOptions(configuration: .debug)
    var xcode = false

    @discardableResult
    func run() async throws -> URL {
        // TODO: support running inside a child directory

        let contents = try FileManager.default.contentsOfDirectory(atPath: ".")
        guard contents.contains("Package.swift")
            || contents.contains(where: { $0.hasPrefix("Package@") && $0.hasSuffix(".swift") })
            else {
            throw Console.Error("Could not find Package.swift in this directory.")
        }

        try await EnsureSDKOperation(quiet: true).run()

        print("Planning...")

        let schema: PackSchema
        let configPath = URL(fileURLWithPath: "xtool.yml")
        if FileManager.default.fileExists(atPath: configPath.path) {
            schema = try await PackSchema(url: configPath)
        } else {
            schema = .default
            print("""
            warning: Could not locate configuration file '\(configPath.path)'. Using default \
            configuration with 'com.example' organization ID.
            """)
        }

        let buildSettings = try await BuildSettings(
            configuration: buildOptions.configuration,
            triple: triple ?? Self.defaultTriple,
            options: []
        )

        let planner = Planner(
            buildSettings: buildSettings,
            schema: schema
        )
        let plan = try await planner.createPlan()
        await LSPConfig.tryEnsure(plan: plan, settings: buildSettings, schema: schema)

        if xcode {
            return try await XcodePacker(plan: plan).createProject()
        }

        let packer = Packer(
            buildSettings: buildSettings,
            plan: plan
        )
        let bundle = try await packer.pack()

        let productsWithEntitlements = plan
            .allProducts
            .compactMap { p in p.entitlementsPath.map { (p, $0) } }
        if !productsWithEntitlements.isEmpty {
            let mapping = try await withThrowingTaskGroup(of: (URL, Entitlements).self) { group in
                for (product, path) in productsWithEntitlements {
                    group.addTask {
                        let data = try await Data(reading: URL(fileURLWithPath: path))
                        let decoder = PropertyListDecoder()
                        let entitlements = try decoder.decode(Entitlements.self, from: data)
                        return (product.directory(inApp: bundle), entitlements)
                    }
                }
                return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
            }
            print("Applying entitlements...")
            try await Signer.first().sign(
                app: bundle,
                identity: .adhoc,
                entitlementMapping: mapping,
                progress: { _ in }
            )
        }

        return bundle
    }
}

struct DevXcodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-xcode-project",
        abstract: "Generate Xcode project"
    )

    func run() async throws {
        let request = try await DevBuildRequest.load()
        try request.validate(route: .xcode)
        @Dependency(\.devCommandClient) var client
        let result = try await client.legacyPack(request.triple, .debug, true)
        print("Wrote to \(result.path)")
    }
}

struct DevBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build app with SwiftPM",
        discussion: """
        Build the SwiftPM-based app in the current directory. macOS targets require
        --defer-signing and produce an app plus a signing manifest and preserved
        entitlement inputs for signing later on a Mac. This command does not issue
        Developer ID certificates or notarize apps.
        """
    )

    @OptionGroup var packOptions: PackOperation.BuildOptions
    @OptionGroup var macOptions: MacBuildOptions

    @Flag(
        name: .shortAndLong,
        help: "Codesign the built app",
    ) var sign = false

    @Flag(
        name: .shortAndLong,
        help: "Output a .ipa file instead of a .app"
    ) var ipa = false

    @Flag(help: "Defer macOS signing and preserve inputs for a downstream Mac signer")
    var deferSigning = false

    @Option(
        help: ArgumentHelp(
            "Custom target triple to build for",
            discussion: "Overrides xtool.yml target; otherwise defaults to '\(PackOperation.defaultTriple)'"
        )
    ) var triple: String?

    func run() async throws {
        let request = try await DevBuildRequest.load(cliTriple: triple)
        try request.validate(route: .build(sign: sign, ipa: ipa, deferSigning: deferSigning))

        if request.platform == .macOS {
            let output = try await DeferredMacBuildOperation(
                request: request, configuration: packOptions.configuration, options: macOptions
            ).run()
            print("Wrote to \(output.bundle.path)")
            print("Signing inputs: \(output.manifest.path)")
            print("Artifact inventory: \(MacArtifact.manifestURL(for: output.bundle).path)")
            return
        }
        guard macOptions.arguments.isEmpty else { throw Console.Error("SDK and scratch overrides require a macOS target") }

        let signingAuthToken: AuthToken?
        if sign {
            guard let token = try AuthToken.savedIfPresent() else {
                throw Console.Error("`build --sign` requires logging in with `xtool auth`")
            }
            signingAuthToken = token
        } else {
            signingAuthToken = nil
        }

        @Dependency(\.devCommandClient) var client
        let url = try await client.legacyPack(request.triple, packOptions.configuration, false)

        if let signingAuthToken {
            let installDelegate = XToolInstallerDelegate()
            let installer = IntegratedInstaller(
                auth: signingAuthToken.authData(),
                delegate: installDelegate
            )
            do {
                defer { print() }
                try await installer.signInPlace(app: url)
            } catch let error as CancellationError {
                throw error
            } catch {
                print("Error: \(error)")
                throw ExitCode.failure
            }
        }

        let finalURL: URL
        if ipa {
            @Dependency(\.zipCompressor) var compressor
            finalURL = url.deletingPathExtension().appendingPathExtension("ipa")
            let tmpDir = try TemporaryDirectory(name: "Payload")
            let payloadDir = tmpDir.url
            try FileManager.default.moveItem(at: url, to: payloadDir.appendingPathComponent(url.lastPathComponent))
            let ipaURL = try await compressor.compress(directory: payloadDir) { progress in
                if let progress {
                    let percent = Int(progress * 100)
                    print("\rPackaging... \(percent)%", terminator: "")
                } else {
                    print("\rPackaging...", terminator: "")
                }
            }
            print()
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: ipaURL, to: finalURL)
        } else {
            finalURL = url
        }

        print("Wrote to \(finalURL.path)")
    }
}

struct DevRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build and run app with SwiftPM",
        discussion: """
        Build and run the configured app. macOS apps run locally without adding signatures.
        Use --app to run an existing macOS app without rebuilding. Output is streamed to
        this terminal and the app's exit status is returned.
        """
    )

    @OptionGroup var packOptions: PackOperation.BuildOptions

    @Option(help: "Override the configured target triple")
    var triple: String?

    @Option(help: "Run an existing macOS .app without building or signing it")
    var app: String?

    @Argument(parsing: .captureForPassthrough, help: "Arguments passed to the macOS app after --")
    var arguments: [String] = []

    var appArguments: [String] { arguments.first == "--" ? Array(arguments.dropFirst()) : arguments }

    #if os(macOS)
    @Flag(
        name: .shortAndLong,
        help: "Target the iOS Simulator"
    ) var simulator = false

    var simulatorTriple: String? {
        if simulator {
            #if arch(arm64)
            return "arm64-apple-ios-simulator"
            #elseif arch(x86_64)
            return "x86_64-apple-ios-simulator"
            #else
            #error("Unsupported architecture")
            #endif
        }
        return nil
    }
    #else
    var simulatorTriple: String? { nil }
    #endif

    @OptionGroup var connectionOptions: ConnectionOptions

    func run() async throws {
        if let app {
            guard triple == nil, simulatorTriple == nil else {
                throw Console.Error("--app cannot be combined with --triple or --simulator")
            }
            try await MacRunOperation.run(bundle: URL(fileURLWithPath: app), arguments: appArguments)
            return
        }
        // Validate the configured target before the simulator override can hide it.
        let request = try await DevBuildRequest.load(cliTriple: triple)
        try request.validate(route: .run)
        if request.platform == .macOS {
            guard simulatorTriple == nil else { throw Console.Error("--simulator cannot run a macOS target") }
            try MacRunOperation.requireHost()
            let output = try await DeferredMacBuildOperation(request: request, configuration: packOptions.configuration).run()
            try await MacRunOperation.run(bundle: output.bundle, arguments: appArguments)
            return
        }
        guard arguments.isEmpty else { throw Console.Error("App arguments currently require a macOS target") }
        @Dependency(\.devCommandClient) var client
        let output = try await client.legacyPack(simulatorTriple ?? request.triple, packOptions.configuration, false)

        #if os(macOS)
        if simulator {
            try await SimInstallOperation(path: output).run()
            return
        }
        #endif

        let token = try AuthToken.saved()

        let device = try await connectionOptions.client()
        print("Installing to device: \(device.deviceName) (udid: \(device.udid))")

        let installDelegate = XToolInstallerDelegate()
        let installer = IntegratedInstaller(
            auth: token.authData(),
            delegate: installDelegate
        )

        defer { print() }

        do {
            try await installer.install(
                app: output,
                udid: device.udid,
                lookupMode: .only(device.connectionType),
                configureDevice: false,
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            print("\nError: \(error)")
            throw ExitCode.failure
        }
    }
}

/// Select the effective target before auth, SDK setup, LSP writes, or packing.
/// Planner resolves the deployment minimum later, with package metadata available.
struct DevBuildRequest: Sendable {
    enum Route {
        case build(sign: Bool, ipa: Bool, deferSigning: Bool)
        case run
        case xcode
    }

    let schema: PackSchema
    let triple: String
    let platform: TargetPlatform
    let directory: URL

    init(schema: PackSchema, cliTriple: String? = nil, directory: URL) throws {
        self.schema = schema
        self.triple = cliTriple ?? schema.target ?? ResolvedTarget.defaultTriple
        self.platform = try TargetTriple(triple).platform
        self.directory = directory
        try schema.validate(for: platform)
    }

    static func load(cliTriple: String? = nil) async throws -> Self {
        @Dependency(\.devCommandClient) var client
        let directory = client.currentDirectory()
        let schema = try await client.loadSchema(directory)
        return try Self(schema: schema, cliTriple: cliTriple, directory: directory)
    }

    func validate(route: Route) throws {
        switch route {
        case .build(let sign, let ipa, let deferSigning):
            if platform == .macOS {
                guard !sign, !ipa else {
                    throw Console.Error("""
                    macOS builds do not support --sign, IPA packaging, or device provisioning; use --defer-signing
                    """)
                }
                guard deferSigning else {
                    throw Console.Error("macOS builds require --defer-signing; sign the resulting app later on a Mac")
                }
            } else if deferSigning {
                throw Console.Error("--defer-signing requires a macOS target")
            }
        case .run:
            break
        case .xcode:
            guard platform != .macOS else {
                throw Console.Error("""
                Xcode project generation for macOS is unsupported
                """)
            }
        }
    }
}

struct MacBuildOptions: ParsableArguments {
    @Option(name: .customLong("swift-sdks-path"), help: "Use a prepared Swift SDK directory for macOS builds")
    var swiftSDKsPath: String?

    @Option(help: "Use a separate SwiftPM scratch directory for macOS builds")
    var scratchPath: String?

    var arguments: [String] {
        (swiftSDKsPath.map { ["--swift-sdks-path", $0] } ?? [])
            + (scratchPath.map { ["--scratch-path", $0] } ?? [])
    }
}

struct DeferredMacBuildOperation {
    let request: DevBuildRequest
    let configuration: BuildConfiguration
    var options: MacBuildOptions?

    struct Output {
        let bundle: URL
        let manifest: URL
    }

    func run() async throws -> Output {
        guard request.platform == .macOS else {
            throw Console.Error("Deferred macOS packing requires a macOS target")
        }
        #if !os(macOS)
        guard configuration == .release else {
            throw Console.Error("macOS Debug builds on Linux need unavailable codesign support; use --configuration release")
        }
        #endif
        let contents = try FileManager.default.contentsOfDirectory(atPath: request.directory.path)
        guard contents.contains("Package.swift")
            || contents.contains(where: { $0.hasPrefix("Package@") && $0.hasSuffix(".swift") }) else {
            throw Console.Error("Could not find Package.swift in this directory.")
        }
        @Dependency(\.devCommandClient) var client
        if options?.swiftSDKsPath == nil { try await client.ensureSDK() }
        print("Planning...")
        let settings = try await BuildSettings(
            configuration: configuration, triple: request.triple,
            buildSystem: .swiftPM, packagePath: request.directory.path, options: options?.arguments ?? []
        )
        let plan = try await Planner(buildSettings: settings, schema: request.schema).createPlan()
        await LSPConfig.tryEnsure(plan: plan, settings: settings, schema: request.schema, currentDirectory: request.directory)
        // This deliberately bypasses PackOperation's automatic entitlement signing.
        let bundle = try await client.deferredPack(settings, plan)
        let manifest = try DeferredSigningHandoff.write(plan: plan, bundle: bundle, sourceDirectory: request.directory)
        try MacArtifact.write(bundle: bundle, signingManifest: manifest)
        return Output(bundle: bundle, manifest: manifest)
    }
}

enum DeferredSigningHandoff {
    /// Keep signing inputs outside the bundle, so they cannot alter bundle resources.
    static func write(plan: Plan, bundle: URL, sourceDirectory: URL) throws -> URL {
        guard plan.target.platform == .macOS else {
            throw Console.Error("Deferred signing handoffs require a macOS plan")
        }
        var manifest = DeferredSigningManifest(plan: plan)
        let name = bundle.deletingPathExtension().lastPathComponent
        let parent = bundle.deletingLastPathComponent()
        let inputs = parent.appendingPathComponent("\(name).signing-inputs", isDirectory: true)
        let manifestURL = MacArtifact.signingManifestURL(for: bundle)
        var files: [(String, Data)] = []
        for index in manifest.products.indices {
            guard let path = manifest.products[index].entitlementsPath else { continue }
            let source = URL(fileURLWithPath: path, relativeTo: sourceDirectory)
            let data = try Data(contentsOf: source)
            guard try PropertyListSerialization.propertyList(from: data, options: [], format: nil) is [String: Any] else {
                throw Console.Error("Entitlements must be a property-list dictionary: \(path)")
            }
            let filename = "\(index).entitlements.plist"
            files.append((filename, data))
            manifest.products[index].entitlementsPath = "\(inputs.lastPathComponent)/\(filename)"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        if FileManager.default.fileExists(atPath: inputs.path) {
            try FileManager.default.removeItem(at: inputs)
        }
        if !files.isEmpty {
            try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
            for (filename, contents) in files {
                try contents.write(to: inputs.appendingPathComponent(filename), options: .atomic)
            }
        }
        try data.write(to: manifestURL, options: .atomic)
        return manifestURL
    }
}

/// External effects are replaceable through swift-dependencies, including packing.
struct DevCommandClient: Sendable {
    var currentDirectory: @Sendable () -> URL
    var loadSchema: @Sendable (URL) async throws -> PackSchema
    var ensureSDK: @Sendable () async throws -> Void
    var legacyPack: @Sendable (String, BuildConfiguration, Bool) async throws -> URL
    var deferredPack: @Sendable (BuildSettings, Plan) async throws -> URL
}

extension DevCommandClient: DependencyKey {
    static let liveValue = Self(
        currentDirectory: { URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true) },
        loadSchema: { directory in
            let path = directory.appendingPathComponent("xtool.yml")
            if FileManager.default.fileExists(atPath: path.path) {
                return try await PackSchema(url: path)
            }
            print("""
            warning: Could not locate configuration file '\(path.path)'. Using default \
            configuration with 'com.example' organization ID.
            """)
            return .default
        },
        ensureSDK: { try await EnsureSDKOperation(quiet: true).run() },
        legacyPack: { triple, configuration, xcode in
            try await PackOperation(triple: triple, buildOptions: .init(configuration: configuration), xcode: xcode).run()
        },
        deferredPack: { settings, plan in
            try await Packer(buildSettings: settings, plan: plan).pack()
        }
    )

    static let testValue = Self(
        currentDirectory: { URL(fileURLWithPath: "/unexpected-command-directory") },
        loadSchema: { _ in throw StringError("Unexpected schema load") },
        ensureSDK: { throw StringError("Unexpected SDK setup") },
        legacyPack: { _, _, _ in throw StringError("Unexpected iOS packing") },
        deferredPack: { _, _ in throw StringError("Unexpected deferred packing") }
    )
}

extension DependencyValues {
    var devCommandClient: DevCommandClient {
        get { self[DevCommandClient.self] }
        set { self[DevCommandClient.self] = newValue }
    }
}

struct DevCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Build and run an xtool SwiftPM project",
        subcommands: [
            DevXcodeCommand.self,
            DevBuildCommand.self,
            DevRunCommand.self,
            DevVerifyCommand.self,
            DevBSPCommand.self,
        ],
        defaultSubcommand: DevRunCommand.self
    )
}

extension BuildConfiguration: ExpressibleByArgument {}

#if os(macOS)
import Subprocess

struct SimInstallOperation {
    var path: URL

    // TODO: allow customizing this
    var simulator = "booted"

    func run() async throws {
        try await Subprocess.run(
            .path("/usr/bin/xcrun"),
            arguments: ["simctl", "install", simulator, path.path],
            output: .discarded
        )
        .checkSuccess()
        print("Installed to simulator")
    }
}
#endif
