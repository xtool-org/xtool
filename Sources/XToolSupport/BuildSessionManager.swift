import XCLIUtils
import XUtils
import XPIF
import SwiftBuild
import Foundation
import Dependencies

actor BuildSessionManager {
    let service: SWBBuildService
    let session: SWBBuildServiceSession

    #if os(macOS)
    nonisolated let metalToolchain: MetalToolchain?
    #else
    nonisolated let darwinSDK: DarwinSDK
    #endif

    private let planningDelegate = PlanningOperationDelegate()

    private var hasCalledClose = false

    init() async throws {
        #if !os(macOS)
        self.darwinSDK = try DarwinSDK.current().orThrow(Console.Error("Darwin SDK not installed"))
        let toolsetPath = darwinSDK.bundle.appending(path: "toolset/bin").path
        // swb looks here for tools first...
        setenv("__XCODE_BUILT_PRODUCTS_DIR_PATHS", toolsetPath, 1)
        // ...but also provide PATH as a fallback for nested tool invocations
        setenv("PATH", "\(toolsetPath):\(ProcessInfo.processInfo.environment["PATH"] ?? "")", 1)
        setenv("XCODE_EXTRA_PLATFORM_FOLDERS", "\(darwinSDK.developerDirectory.path)/Platforms", 1)
        if let executablePath = Bundle.main.executablePath {
            setenv("XTL_LOOPBACK_PATH", executablePath, 1)
        }
        #endif

        self.service = try await SWBBuildService(
            connectionMode: .xtool,
        )

        Signposter.track("Creating build session")

        #if os(macOS)
        self.metalToolchain = await MetalToolchain.current.value
        let environment = metalToolchain?.sessionEnvironment(inheriting: ProcessInfo.processInfo.environment)
        let (result, diagnostics) = await service.createSession(
            name: "xtool",
            developerPath: nil,
            resourceSearchPaths: [],
            cachePath: nil,
            inferiorProductsPath: nil,
            environment: environment,
        )
        #else
        let (result, diagnostics) = await service.createSession(
            name: "xtool",
            swiftToolchainPath: try await d.toolchain.toolchainRoot.string,
            resourceSearchPaths: [],
            cachePath: nil,
            inferiorProductsPath: nil,
            environment: nil,
        )
        #endif

        if !diagnostics.isEmpty {
            d.out.print("Diagnostics:")
            for diagnostic in diagnostics {
                d.out.print(diagnostic)
            }
        }
        self.session = try result.get()
    }

    /// Must call this before deinit. Idempotent.
    func close() async {
        guard !hasCalledClose else { return }
        hasCalledClose = true

        do {
            try await session.close()
        } catch {
            d.out.print("Error closing build session: \(error)")
        }

        await service.close()
    }

    func sendPIF(_ container: XPIF.Container) async throws {
        let serialized = try container.data()
        let propertyList = try JSONSerialization.jsonObject(with: serialized, options: [])

        try await session.sendPIF(SWBPropertyListItem(unsafePropertyList: propertyList))

        try await session.setSystemInfo(.default())
        try await session.setUserInfo(.default)
        try await session.setUserPreferences(
            enableDebugActivityLogs: false,
            enableBuildDebugging: false,
            enableBuildSystemCaching: true,
            activityTextShorteningLevel: 3,
            usePerConfigurationBuildLocations: nil,
            // changed from default, allows delegation to our executeExternalTool()
            allowsExternalToolExecution: true,
        )
    }

    func createBuildOperation(request: SWBBuildRequest) async throws -> SWBBuildOperation {
        try await session.createBuildOperation(request: request, delegate: planningDelegate)
    }

    /// Plans (but doesn't run) a build. The caller is responsible for releasing the
    /// resulting build description with `session.releaseBuildDescription(id:)`.
    func createRetainedBuildDescriptionOperation(request: SWBBuildRequest) async throws -> SWBBuildOperation {
        try await session.createBuildOperationForBuildDescriptionOnly(
            request: request,
            delegate: planningDelegate,
            retainBuildDescription: true,
        )
    }

    func generatePreviewInfo(
        request: SWBBuildRequest,
        targetID: String,
        sourceFile: String,
        thunkVariantSuffix: String
    ) async throws -> [SWBPreviewInfo] {
        try await session.generatePreviewInfo(
            for: request,
            targetID: targetID,
            sourceFile: sourceFile,
            thunkVariantSuffix: thunkVariantSuffix,
            delegate: planningDelegate,
        )
    }
}

private final class PlanningOperationDelegate: SWBPlanningOperationDelegate, SWBPreviewDelegate, Sendable {
    let dependencies = withEscapedDependencies(\.self)

    func provisioningTaskInputs(
        targetGUID: String,
        provisioningSourceData: SWBProvisioningTaskInputsSourceData
    ) async -> SWBProvisioningTaskInputs {
        // called on a GCD queue without task locals, so we need to explicitly propagate deps
        await dependencies.yield {
            await _provisioningTaskInputs(
                targetGUID: targetGUID,
                provisioningSourceData: provisioningSourceData
            )
        }
    }

    func _provisioningTaskInputs(
        targetGUID: String,
        provisioningSourceData: SWBProvisioningTaskInputsSourceData
    ) async -> SWBProvisioningTaskInputs {
        // swiftlint:disable:next line_length
        // based on https://github.com/swiftlang/swift-build/blob/02d98b1/Sources/SwiftBuild/ConsoleCommands/SWBServiceConsoleBuildCommand.swift#L491
        guard !provisioningSourceData.signingCertificateIdentifier.isEmpty else {
            return SWBProvisioningTaskInputs()
        }
        let entitlementsDestination = provisioningSourceData.entitlementsDestination
        let signedEntitlements = entitlementsDestination == "Signature"
            ? provisioningSourceData.productTypeEntitlements
                .merging(
                    provisioningSourceData.projectEntitlements ?? [:],
                    uniquingKeysWith: { _, new in new }
                )
            : [:]
        let simulatedEntitlements = entitlementsDestination == "__entitlements"
            ? provisioningSourceData.productTypeEntitlements
                .merging(
                    ["application-identifier": .plString(provisioningSourceData.bundleIdentifier)],
                    uniquingKeysWith: { _, new in new }
                )
                .merging(
                    provisioningSourceData.projectEntitlements ?? [:],
                    uniquingKeysWith: { _, new in new }
                )
            : [:]
        return SWBProvisioningTaskInputs(
            identityHash: "-",
            identityName: "-",
            signedEntitlements: signedEntitlements
                .merging(
                    provisioningSourceData.sdkRoot.contains("simulator")
                        ? ["com.apple.security.get-task-allow": .plBool(true)]
                        : [:],
                    uniquingKeysWith: { _, new in new }
                ),
            simulatedEntitlements: simulatedEntitlements,
        )
    }

    func executeExternalTool(
        commandLine: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> SWBExternalToolResult {
        try await dependencies.yield {
            try await self._executeExternalTool(
                commandLine: commandLine,
                workingDirectory: workingDirectory,
                environment: environment
            )
        }
    }

    private func _executeExternalTool(
        commandLine: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> SWBExternalToolResult {
        return try await d.emulatedTools.execute(
            commandLine: commandLine,
            workingDirectory: workingDirectory,
            environment: environment,
        ).swb
    }
}

extension EmulatedToolResult {
    fileprivate var swb: SWBExternalToolResult {
        switch self {
        case .deferred:
            .deferred
        case .result(let status, let stdout, let stderr):
            .result(status: status.swb, stdout: stdout, stderr: stderr)
        }
    }
}

extension EmulatedToolExitStatus {
    fileprivate var swb: SWBProcessExitStatus {
        switch self {
        case .exit(let code):
            .exit(code)
        case .uncaughtSignal(let signal):
            .uncaughtSignal(signal)
        }
    }
}
