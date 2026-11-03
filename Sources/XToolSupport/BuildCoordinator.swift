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

    init(description: BuildDescription) async throws {
        self.pifContainer = description.pif

        Signposter.track("Creating BuildSessionManager")

        let sessionManager = try await BuildSessionManager()
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

            let xtoolDir = description.directory.appending(path: "xtool")
            // if you have a macOS Xcode project with a package dependency, and build in debug
            // mode, the Xcode targets will use [arm64, x86_64] but the package targets will
            // only declare [arm64], causing the build to fail
            overrides["ONLY_ACTIVE_ARCH"] = "YES"
            // force ad-hoc signing during the build process. we'll provision & re-sign
            // with the proper identity later.
            #if os(macOS)
            overrides["CODE_SIGN_IDENTITY"] = "-"
            #else
            // on Linux, host targets (eg macros) should not receive Darwin codesigning flags
            overrides["CODE_SIGN_IDENTITY[__destination_platform=YES]"] = "-"
            #endif
            overrides["AD_HOC_CODE_SIGNING_ALLOWED"] = "YES"
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
            overrides["OTHER_SWIFT_FLAGS[__destination_platform=YES]"] = """
            $(inherited) \
            -external-plugin-path "\(bundle)/toolset/plugins#\(bundle)/toolset/bin/OpenAppleMacrosServer" \
            -Xfrontend -enable-cross-import-overlays
            """
            #endif

            var overridesTable = SWBSettingsTable()
            for (key, value) in overrides {
                overridesTable.set(value: value, for: key)
            }
            parameters.overrides.synthesized = overridesTable
            var request = SWBBuildRequest()
            request.parameters = parameters
            request.useImplicitDependencies = true
            request.setDerivedDataPath(xtoolDir.appending(path: ".xtool-tmp/DerivedData"))
            self.buildRequest = request
        } catch {
            await sessionManager.close()
            throw error
        }
    }

    func close() async {
        await sessionManager.close()
    }

    func mainProductGUID() throws -> String {
        let apps = pifContainer.workspace.projects.flatMap(\.targets).compactMap { base -> XPIF.Target? in
            guard case let .target(target) = base, target.productType == .application else { return nil }
            return target
        }
        guard apps.count == 1, let app = apps.first else {
            throw Console.Error("Expected one application target, found \(apps.count).")
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

    func createBuildOperation() async throws -> SWBBuildOperation {
        var request = buildRequest
        if request.configuredTargets.isEmpty {
            request.configuredTargets = [SWBConfiguredTarget(guid: try mainProductGUID())]
        }
        return try await sessionManager.createBuildOperation(request: request)
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
