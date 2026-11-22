import Dependencies
import XCLIUtils
import XPIF
import Foundation
import XUtils
import Subprocess
import SwiftBuild

public actor BuildCoordinator {
    let sessionManager: BuildSessionManager
    let buildRequest: SWBBuildRequest
    let pifContainer: XPIF.Container
    let targetSelection: BuildDescription.TargetSelection?

    private var buildDescriptionID: SWBBuildDescriptionID?

    /// - Parameter hotReloadable: Build with the flags that `HotReloader` needs
    ///   to swap out code in the running app.
    init(description: BuildDescription, hotReloadable: Bool = false) async throws {
        self.pifContainer = description.pif
        self.targetSelection = description.targetSelection

        Signposter.track("Creating BuildSessionManager")

        let sessionManager = try await withDependencies {
            $0.isHotReloadableBuild = hotReloadable
        } operation: {
            try await BuildSessionManager()
        }
        self.sessionManager = sessionManager

        do {
            Signposter.track("Sending PIF to build service")

            try await sessionManager.sendPIF(pifContainer)

            let targetInfo = try await sessionManager.session.buildTargetInfo(triple: description.triple)
            // buildTargetInfo validates the triple's structure. Like SwiftPM's archName,
            // preserve the architecture spelling from its first component.
            let arch = String(description.triple.prefix { $0 != "-" })
            var parameters = SWBBuildParameters()
            parameters.activeRunDestination = SWBRunDestinationInfo(
                buildTarget: .toolchainSDK(
                    platform: targetInfo.platformName,
                    sdk: targetInfo.sdkName,
                    sdkVariant: targetInfo.sdkVariant,
                ),
                targetArchitecture: arch,
                supportedArchitectures: [arch],
                disableOnlyActiveArch: false,
            )
            parameters.activeArchitecture = arch

            var overrides: [String: String] = [:]
            var targetLinkerFlags = "$(inherited)"
            var targetSwiftFlags = "$(inherited)"

            let xtoolDir = description.directory.appending(path: "xtool")
            // if you have a macOS Xcode project with a package dependency, and build in debug
            // mode, the Xcode targets will use [arm64, x86_64] but the package targets will
            // only declare [arm64], causing the build to fail
            overrides["ONLY_ACTIVE_ARCH"] = "YES"
            // force ad-hoc signing during the build process. we'll provision & re-sign
            // with the proper identity later.
            #if os(macOS)
            if let metalToolchain = sessionManager.metalToolchain {
                // Registering the search path alone is insufficient: Swift Build must also
                // select the toolchain before the default toolchain's nonfunctional Metal stubs.
                overrides["TOOLCHAINS"] = "\(metalToolchain.toolchainIdentifier) $(inherited)"
            }
            overrides["CODE_SIGN_IDENTITY"] = "-"
            #else
            // on Linux, host targets (eg macros) should not receive Darwin codesigning flags
            overrides["CODE_SIGN_IDENTITY[__destination_platform=YES]"] = "-"
            #endif
            overrides["AD_HOC_CODE_SIGNING_ALLOWED"] = "YES"
            // when LINKER_DRIVER=swiftc, LC_BUILD_VERSION.sdk is not set correctly by default.
            // specifically, it invokes the clang linker-driver with `--sysroot ...` but Clang
            // only looks at `-isysroot` to determine the SDK version. this primarily affects
            // SwiftPM targets since they use LINKER_DRIVER=auto (instead of `=clang`). fix
            // by explicitly passing `-isysroot` when the driver is swiftc.
            overrides["XTL_LDFLAGS_swiftc"] = #"-Xclang-linker -isysroot -Xclang-linker "$(SDKROOT)""#
            targetLinkerFlags += " $(XTL_LDFLAGS_$(LINKER_DRIVER))"
            if hotReloadable {
                // lets us ask for per-file compile commands via generatePreviewInfo
                overrides["ENABLE_XOJIT_PREVIEWS"] = "YES"
                // mutually exclusive with ENABLE_XOJIT_PREVIEWS
                overrides["ENABLE_PREVIEWS"] = "NO"
                // XOJIT previews would otherwise split the app into a stub executable + debug dylib
                overrides["ENABLE_DEBUG_DYLIB"] = "NO"
                // route calls through stubs so that reloaded symbols can be interposed
                targetLinkerFlags += " -Xlinker -interposable"
                // https://kyleye.top/posts/debugreplaceableview-multiple-type-erasers/
                // https://www.guardsquare.com/blog/behind-swiftui-previews
                overrides["SWIFT_ENABLE_OPAQUE_TYPE_ERASURE"] = "YES"
                targetSwiftFlags += " -Xfrontend -enable-private-imports"
            }
            // Only override deployment targets when the triple explicitly includes a version.
            // Otherwise each package retains the deployment targets from its manifest.
            if let setting = targetInfo.deploymentTargetSettingName, let version = targetInfo.deploymentTarget {
                overrides[setting] = version
            }

            switch description.configuration {
            case .debug:
                parameters.configurationName = "Debug"
                parameters.action = "build"
            case .release:
                parameters.configurationName = "Release"
                parameters.action = "install"
                overrides["DSTROOT"] = xtoolDir.appending(path: ".xtool-tmp/Install/\(description.triple)").path
                overrides["INSTALL_PATH"] = "/"
            }

            #if !os(macOS)
            let bundle = sessionManager.darwinSDK.bundle.path
            // we don't have appintentsmetadataprocessor yet
            overrides["LM_SKIP_METADATA_EXTRACTION"] = "1"
            // Our toolset doesn't yet include the tapi tool
            overrides["EAGER_LINKING"] = "NO"
            overrides["GENERATE_TEXT_BASED_STUBS"] = "NO"
            overrides["GENERATE_INTERMEDIATE_TEXT_BASED_STUBS"] = "NO"
            overrides["SUPPORTS_TEXT_BASED_API"] = "NO"
            // equivalent of our SwiftPM-era `toolset.json` config
            let bin = "\(bundle)/toolset/bin"
            overrides["PBXCP_BITCODE_STRIP_TOOL[__destination_platform=YES]"] = "\(bin)/bitcode_strip"
            overrides["ALTERNATE_LINKER[__destination_platform=YES]"] = "lld"
            overrides["ALTERNATE_LINKER_PATH[__destination_platform=YES]"] = "\(bin)/ld64.lld"
            overrides["AR[__destination_platform=YES]"] = "\(bin)/llvm-lib"
            overrides["LIBTOOL[__destination_platform=YES]"] = "\(bin)/llvm-lib"
            let developerDir = sessionManager.darwinSDK.developerDirectory.path
            let swiftResourceDir = "\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift"
            overrides["SWIFT_RESOURCE_DIR[__destination_platform=YES]"] = swiftResourceDir
            let runtimeResourcePath = try await d.toolchain.runtimeResourcePath
            let hostClangResources = runtimeResourcePath.appending("clang")
            // Compile with the host's intrinsic headers...
            overrides["CLANG_RESOURCE_DIR[__destination_platform=YES]"] = hostClangResources.string
            // ...but at link time, point to Apple's Darwin compiler runtimes (incl OS availability helpers)
            // from the Xcode toolchain.
            overrides["CLANG_RESOURCE_DIR_CLANG[__destination_platform=YES]"] = "\(swiftResourceDir)/clang"
            overrides["CLANG_RESOURCE_DIR_SWIFTC[__destination_platform=YES]"] = "\(swiftResourceDir)/clang"
            // Use OpenAppleMacrosServer, which reimplements Apple's proprietary macros.
            // Also explicitly enable cross-import-overlays: they're on by default in Apple Swift
            // but off by default in OSS Swift.
            targetSwiftFlags += " " + """
            -external-plugin-path "\(bundle)/toolset/plugins#\(bundle)/toolset/bin/OpenAppleMacrosServer" \
            -Xfrontend -enable-cross-import-overlays
            """
            #endif

            overrides["OTHER_LDFLAGS[__destination_platform=YES]"] = targetLinkerFlags
            overrides["OTHER_SWIFT_FLAGS[__destination_platform=YES]"] = targetSwiftFlags

            var overridesTable = SWBSettingsTable()
            for (key, value) in overrides {
                overridesTable.set(value: value, for: key)
            }
            parameters.overrides.synthesized = overridesTable
            var request = SWBBuildRequest()
            request.parameters = parameters
            request.useImplicitDependencies = description.targetSelection?.buildImplicitDependencies ?? true
            request.configuredTargets = description.targetSelection?.buildTargets.map {
                SWBConfiguredTarget(guid: $0.value)
            } ?? []
            request.setDerivedDataPath(xtoolDir.appending(path: ".xtool-tmp/DerivedData"))
            self.buildRequest = request
        } catch {
            await sessionManager.close()
            throw error
        }
    }

    func close() async {
        if let buildDescriptionID {
            self.buildDescriptionID = nil
            await sessionManager.session.releaseBuildDescription(id: buildDescriptionID)
        }
        await sessionManager.close()
    }

    func mainProductGUID() throws -> String {
        if let targetSelection { return targetSelection.application.value }
        let apps = pifContainer.workspace.projects.flatMap(\.targets).compactMap { base -> XPIF.Target? in
            guard case let .target(target) = base, target.productType == .application else { return nil }
            return target
        }
        guard apps.count == 1, let app = apps.first else {
            throw Console.Error("""
                Expected one application target in Xcode project or workspace, found \(apps.count). \
                Select an application with --scheme or 'scheme' in xtool.yml.
                """)
        }
        return app.id.value
    }

    // TODO: swb: use product info request
    func mainProductDetails() async throws -> (productName: String, bundleID: String, output: URL) {
        let guid = try mainProductGUID()
        // PBX product references can have stale names. Resolve the actual output with Swift Build,
        // including configuration, SDK conditions, xcconfigs, and build setting expressions.
        let fullProductName = try await sessionManager.session.evaluateMacroAsString(
            "FULL_PRODUCT_NAME", level: .target(guid),
            buildParameters: buildRequest.parameters,
            overrides: nil,
        )
        let bundleID = try await sessionManager.session.evaluateMacroAsString(
            "PRODUCT_BUNDLE_IDENTIFIER", level: .target(guid),
            buildParameters: buildRequest.parameters,
            overrides: nil,
        )
        let targetBuildDirectory = try await sessionManager.session.evaluateMacroAsString(
            "TARGET_BUILD_DIR", level: .target(guid),
            buildParameters: buildRequest.parameters,
            overrides: nil,
        )
        return (
            productName: fullProductName.withoutSuffix(".app"),
            bundleID: bundleID,
            output: URL(filePath: targetBuildDirectory).appending(path: fullProductName)
        )
    }

    func mainBuildRequest() throws -> SWBBuildRequest {
        var request = buildRequest
        if request.configuredTargets.isEmpty {
            request.configuredTargets = [SWBConfiguredTarget(guid: try mainProductGUID())]
        }
        return request
    }

    func createBuildOperation() async throws -> SWBBuildOperation {
        try await sessionManager.createBuildOperation(request: mainBuildRequest())
    }

    struct SourceFile: Sendable {
        var path: String
        var language: SWBSourceLanguage?
        var target: SWBConfiguredTargetIdentifier
        /// The toolchain used to build `target`, if known.
        var toolchain: String?
    }

    /// The source files of every target in the main build.
    func sourceFiles() async throws -> [SourceFile] {
        let buildDescription = try await retainedBuildDescription()
        let request = try mainBuildRequest()
        let targets = try await sessionManager.session.configuredTargets(
            buildDescription: buildDescription,
            buildRequest: request
        )
        let toolchains = Dictionary(
            targets.map { ($0.identifier, $0.toolchain?.pathString) },
            uniquingKeysWith: { first, _ in first }
        )
        return try await sessionManager.session.sources(
            of: targets.map(\.identifier),
            buildDescription: buildDescription,
            buildRequest: request
        ).flatMap { info in
            info.sourceFiles.map {
                SourceFile(
                    path: $0.path.pathString,
                    language: $0.language,
                    target: info.configuredTarget,
                    toolchain: toolchains[info.configuredTarget] ?? nil
                )
            }
        }
    }

    struct RecompileCommand: Sendable {
        /// The frontend invocation, starting with the frontend executable.
        var commandLine: [String]
        /// Where `commandLine` writes the object file.
        var objectFile: String
        /// The SDK and target triple to link `objectFile` against.
        var sdk: String
        var target: String
    }

    /// A frontend command that recompiles `file` in the context of its module in the main build.
    ///
    /// Requires `hotReloadable`.
    func recompileCommand(for file: SourceFile) async throws -> RecompileCommand {
        let guid = file.target.targetGUID.rawValue
        // XOJIT preview "thunks" are the original file compiled as the primary file of its module.
        let infos = try await sessionManager.generatePreviewInfo(
            request: mainBuildRequest(),
            targetID: guid,
            sourceFile: file.path,
            thunkVariantSuffix: "xtool"
        )
        guard let info = infos.first(where: { !$0.compileCommandLine.isEmpty }) else {
            throw Console.Error("Could not determine compile command for \(file.path)")
        }
        return RecompileCommand(
            commandLine: info.compileCommandLine,
            objectFile: info.thunkObjectFile,
            sdk: try await evaluate("SDKROOT", target: guid, arch: info.architecture),
            // what the Swift compiler spec passes as -target
            target: try await evaluate("SWIFT_TARGET_TRIPLE", target: guid, arch: info.architecture)
        )
    }

    private func evaluate(_ macro: String, target guid: String, arch: String) async throws -> String {
        try await sessionManager.session.evaluateMacroAsString(
            macro, level: .target(guid),
            buildParameters: buildRequest.parameters,
            // only set per-arch during task construction
            overrides: ["CURRENT_ARCH": arch],
        )
    }

    private func retainedBuildDescription() async throws -> SWBBuildDescriptionID {
        if let buildDescriptionID { return buildDescriptionID }
        // after a build, this is served from Swift Build's build description cache
        let operation = try await sessionManager.createRetainedBuildDescriptionOperation(
            request: mainBuildRequest()
        )
        var id: SWBBuildDescriptionID?
        for await event in try await operation.start() {
            if case .reportBuildDescription(let info) = event {
                id = SWBBuildDescriptionID(info.buildDescriptionID)
            }
        }
        await operation.waitForCompletion()
        guard operation.state == .succeeded, let id else {
            throw Console.Error("Failed to compute build description")
        }
        // a concurrent call may have beaten us to it
        if let buildDescriptionID {
            await sessionManager.session.releaseBuildDescription(id: id)
            return buildDescriptionID
        }
        buildDescriptionID = id
        return id
    }
}

extension SWBBuildRequest {
    fileprivate mutating func setDerivedDataPath(_ derivedDataPath: URL) {
        let arenaInfo = SWBArenaInfo(
            derivedDataPath: derivedDataPath.path,
            buildProductsPath: derivedDataPath.appendingPathComponent("Products").path,
            buildIntermediatesPath: derivedDataPath.appendingPathComponent("Intermediates.noindex").path,
            pchPath: derivedDataPath.path,
            indexRegularBuildProductsPath: nil,
            indexRegularBuildIntermediatesPath: nil,
            indexPCHPath: derivedDataPath.path,
            indexDataStoreFolderPath: derivedDataPath.path,
            indexEnableDataStore: parameters.arenaInfo?.indexEnableDataStore ?? false
        )

        parameters.arenaInfo = arenaInfo
        configuredTargets = configuredTargets.map { configuredTarget in
            var configuredTarget = configuredTarget
            configuredTarget.parameters?.arenaInfo = arenaInfo
            return configuredTarget
        }
    }
}
