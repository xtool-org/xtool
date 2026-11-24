import XPIF
import Foundation
import Subprocess
import SwiftBuild
import BuildServerProtocol
import LanguageServerProtocol
import LanguageServerProtocolTransport
import ToolsProtocolsSwiftExtensions
import XCLIUtils
import XUtils

// Based on SwiftPMBuildServer.swift in swift-package-manager.
// License: https://github.com/swiftlang/swift-package-manager/blob/main/LICENSE.txt

actor XToolBuildServer: QueueBasedMessageHandler {
    let messageHandlingHelper = QueueBasedMessageHandlerHelper(
        signpostLoggingCategory: "xtool-build-server-message-handling",
        createLoggingScope: false
    )
    let messageHandlingQueue = AsyncQueue<BuildServerMessageDependencyTracker>()

    private let connectionToUnderlyingBuildServer: LocalConnection
    private let connectionFromUnderlyingBuildServer: LocalConnection
    private let connectionToClient: any LanguageServerProtocol.Connection
    private var coordinator: BuildCoordinator?
    private let triple: String
    private let scheme: String?
    private let exitHandler: @Sendable (Int) -> Void
    private var packageRoot: URL?
    private var headersByTargetGUID: [String: Set<URL>] = [:]
    private enum State {
        case awaitingInitialize, initializing, initialized, running, shutDown, failed, closed
    }
    private var state = State.awaitingInitialize

    init(
        triple: String,
        scheme: String? = nil,
        connectionToClient: any LanguageServerProtocol.Connection,
        exitHandler: @escaping @Sendable (Int) -> Void
    ) {
        self.triple = triple
        self.scheme = scheme
        self.exitHandler = exitHandler
        self.connectionToClient = connectionToClient
        self.connectionToUnderlyingBuildServer = LocalConnection(receiverName: "underlying-swift-build-server")
        self.connectionFromUnderlyingBuildServer = LocalConnection(receiverName: "xtool-build-server")
    }

    private func initialize(_ request: InitializeBuildRequest) async throws -> InitializeBuildResponse {
        guard state == .awaitingInitialize else {
            throw ResponseError.unknown("Build server has already been initialized")
        }
        guard let directory = request.rootUri.fileURL else {
            throw ResponseError.invalidParams("rootUri must be a file URI")
        }
        state = .initializing
        do {
            guard try await d.toolchain.swiftVersion.supportsSwiftBuild else {
                throw Console.Error("`xtool dev build-server` requires Swift 6.4 or later")
            }
            let project = try await XToolProject.discover(start: directory)
            let description = try await project.describe(configuration: .debug, triple: triple, scheme: scheme)
            let pif = description.pif
            let coordinator = try await BuildCoordinator(description: description)
            var buildRequest = await coordinator.buildRequest
            // The transport may have closed while the coordinator was being created.
            guard state == .initializing else {
                await coordinator.close()
                throw CancellationError()
            }
            self.coordinator = coordinator
            packageRoot = URL(filePath: pif.workspace.path)
            headersByTargetGUID = Self.headerMapping(in: pif)
            buildRequest.configuredTargets = [SWBConfiguredTarget(guid: XPIF.Workspace.umbrellaTargetGUID.value)]
            buildRequest = buildRequest.withIndexBuildArena()
            let server = SWBBuildServer(
                session: coordinator.sessionManager.session,
                buildRequest: buildRequest,
                connectionToClient: connectionFromUnderlyingBuildServer,
                exitHandler: exitHandler
            )
            connectionToUnderlyingBuildServer.start(handler: server)
            connectionFromUnderlyingBuildServer.start(handler: BuildServerClient(connection: connectionToClient))
            var response = try await connectionToUnderlyingBuildServer.send(request)
            guard state == .initializing else { throw CancellationError() }
            response.displayName = "xtool Build Server"
            state = .initialized
            return response
        } catch {
            if state == .initializing { state = .failed }
            throw error
        }
    }

    func close() async {
        guard state != .closed else { return }
        state = .closed
        connectionToUnderlyingBuildServer.close()
        connectionFromUnderlyingBuildServer.close()
        await coordinator?.close()
        coordinator = nil
    }

    func handle(notification: some NotificationType) async {
        switch notification {
        case is OnBuildInitializedNotification:
            guard state == .initialized else { return }
            connectionToUnderlyingBuildServer.send(notification)
            state = .running
        case is OnBuildExitNotification:
            guard state != .closed else { return }
            state = .shutDown
            if packageRoot != nil {
                connectionToUnderlyingBuildServer.send(notification)
            } else {
                exitHandler(0)
            }
        case is OnWatchedFilesDidChangeNotification:
            // The PIF and header mapping are snapshots taken when the server starts.
            break
        default:
            guard state == .running else { return }
            connectionToUnderlyingBuildServer.send(notification)
        }
    }

    func handle<Request: RequestType>(
        request: Request,
        id: RequestID,
        reply: @Sendable @escaping (Result<Request.Response, any Error>) -> Void
    ) async {
        let request = RequestAndReply(request, reply: reply)
        guard state == .running || request.params is InitializeBuildRequest else {
            await request.reply {
                throw ResponseError(code: .serverNotInitialized, message: "Build server is not running")
            }
            return
        }
        switch request {
        case let request as RequestAndReply<InitializeBuildRequest>:
            await request.reply { try await initialize(request.params) }
        case let request as RequestAndReply<BuildShutdownRequest>:
            await request.reply {
                let response = try await connectionToUnderlyingBuildServer.send(request.params)
                state = .shutDown
                return response
            }
        case let request as RequestAndReply<WorkspaceBuildTargetsRequest>:
            await request.reply {
                var response: WorkspaceBuildTargetsResponse
                do {
                    response = try await connectionToUnderlyingBuildServer.send(request.params)
                } catch {
                    logUnderlyingError(error)
                    response = WorkspaceBuildTargetsResponse(targets: [])
                }
                response.targets.append(BuildTarget(
                    id: .xtoolPackageManifest,
                    displayName: "Package Manifest",
                    tags: [.notBuildable],
                    languageIds: [.swift],
                    dependencies: []
                ))
                return response
            }
        case let request as RequestAndReply<BuildTargetSourcesRequest>:
            await request.reply { try await sources(request.params) }
        case let request as RequestAndReply<BuildTargetPrepareRequest>:
            await request.reply {
                var params = request.params
                params.targets.removeAll { $0 == .xtoolPackageManifest }
                guard !params.targets.isEmpty else { return BuildTargetPrepareResponse() }
                return try await connectionToUnderlyingBuildServer.send(params)
            }
        case let request as RequestAndReply<TextDocumentSourceKitOptionsRequest>:
            await request.reply {
                if request.params.target == .xtoolPackageManifest {
                    return try await manifestOptions(request.params)
                }
                if let guid = request.params.target.xtoolTargetGUID,
                   let url = request.params.textDocument.uri.fileURL,
                   headersByTargetGUID[guid]?.contains(where: {
                       $0.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
                   }) == true,
                   let options = try await headerOptions(request.params) {
                    return options
                }
                return try await connectionToUnderlyingBuildServer.send(request.params)
            }
        default:
            await request.reply { try await connectionToUnderlyingBuildServer.send(request.params) }
        }
    }

    private func sources(_ request: BuildTargetSourcesRequest) async throws -> BuildTargetSourcesResponse {
        var params = request
        params.targets.removeAll { $0 == .xtoolPackageManifest }
        var response = BuildTargetSourcesResponse(items: [])
        if !params.targets.isEmpty {
            do {
                response = try await connectionToUnderlyingBuildServer.send(params)
            } catch {
                guard request.targets.contains(.xtoolPackageManifest) else { throw error }
                logUnderlyingError(error)
            }
        }
        for index in response.items.indices {
            guard let guid = response.items[index].target.xtoolTargetGUID else { continue }
            let existing = Set(response.items[index].sources.map(\.uri))
            for header in (headersByTargetGUID[guid] ?? []).sorted(by: { $0.path < $1.path }) {
                let uri = DocumentURI(header)
                guard !existing.contains(uri) else { continue }
                response.items[index].sources.append(SourceItem(
                    uri: uri,
                    kind: .file,
                    generated: false,
                    dataKind: .sourceKit,
                    data: SourceKitSourceItemData(kind: .header).encodeToLSPAny()
                ))
            }
        }
        if request.targets.contains(.xtoolPackageManifest) {
            guard let packageRoot else { throw ResponseError.unknown("Build server is not initialized") }
            let manifests = try FileManager.default.contentsOfDirectory(at: packageRoot, includingPropertiesForKeys: nil)
                .filter { Self.isManifest($0.lastPathComponent) }
                .sorted { $0.path < $1.path }
            response.items.append(SourcesItem(
                target: .xtoolPackageManifest,
                sources: manifests.map { SourceItem(uri: DocumentURI($0), kind: .file, generated: false) }
            ))
        }
        return response
    }

    private func logUnderlyingError(_ error: any Error) {
        connectionToClient.send(OnBuildLogMessageNotification(
            type: .warning,
            message: "Underlying SwiftBuild server reported an error: \(error)"
        ))
    }

    static func isManifest(_ name: String) -> Bool {
        name == "Package.swift" || name.wholeMatch(of: #/^Package@swift-\d+(?:\.\d+)?(?:\.\d+)?\.swift$/#) != nil
    }

    private func manifestOptions(
        _ request: TextDocumentSourceKitOptionsRequest
    ) async throws -> TextDocumentSourceKitOptionsResponse {
        guard let packageRoot, let url = request.textDocument.uri.fileURL,
              url.deletingLastPathComponent().resolvingSymlinksInPath().path == packageRoot.resolvingSymlinksInPath().path,
              Self.isManifest(url.lastPathComponent) else {
            throw ResponseError.unknown("Unknown package manifest: \(request.textDocument.uri)")
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        guard let version = contents.firstMatch(of: #/swift-tools-version:\s*(\d+)\.(\d+)(?:\.(\d+))?/#) else {
            throw ResponseError.unknown("Missing swift-tools-version in \(url.path)")
        }
        let major = Int(version.1) ?? 6
        let languageVersion = major >= 6 ? "6" : major == 5 ? "5" : (Int(version.2) ?? 0) < 2 ? "4" : "4.2"
        let toolsVersion = "\(version.1).\(version.2).\(version.3 ?? "0")"
        // Manifests run on the host, independently of the app's iOS SDK and triple.
        let modules = try await d.toolchain.runtimeResourcePath.appending("pm/ManifestAPI")
        var arguments = ["-swift-version", languageVersion, "-I", modules.string]
        #if os(macOS)
        let sdk = try await Subprocess.run(
            .path("/usr/bin/xcrun"),
            arguments: ["--sdk", "macosx", "--show-sdk-path"],
            output: .string(limit: .max)
        ).checkSuccess().standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        arguments += ["-sdk", sdk]
        #endif
        arguments += ["-package-description-version", toolsVersion, url.path]
        return TextDocumentSourceKitOptionsResponse(compilerArguments: arguments, workingDirectory: packageRoot.path)
    }

    private func headerOptions(
        _ request: TextDocumentSourceKitOptionsRequest
    ) async throws -> TextDocumentSourceKitOptionsResponse? {
        let response = try await connectionToUnderlyingBuildServer.send(BuildTargetSourcesRequest(targets: [request.target]))
        let source = response.items.flatMap(\.sources).first {
            guard $0.kind == .file else { return false }
            switch SourceKitSourceItemData(fromLSPAny: $0.data)?.language {
            case .c, .cpp, .objective_c, .objective_cpp: return true
            case nil: return ["c", "cc", "cp", "cpp", "cxx", "c++", "C", "m", "mm", "M"]
                    .contains($0.uri.fileURL?.pathExtension ?? "")
            default: return false
            }
        }
        guard let source, let sourceURL = source.uri.fileURL, let headerURL = request.textDocument.uri.fileURL else { return nil }
        let substitute = TextDocumentSourceKitOptionsRequest(
            textDocument: TextDocumentIdentifier(source.uri),
            target: request.target,
            language: request.language
        )
        guard var options = try await connectionToUnderlyingBuildServer.send(substitute),
              let index = options.compilerArguments.lastIndex(where: {
                  $0.hasSuffix(sourceURL.lastPathComponent) && sourceURL.path.hasSuffix($0)
              }) else { return nil }
        options.compilerArguments[index] = headerURL.path
        return options
    }

    static func headerMapping(in pif: XPIF.Container) -> [String: Set<URL>] {
        var result: [String: Set<URL>] = [:]
        for project in pif.workspace.projects {
            var files: [XPIF.GUID: URL] = [:]
            func collect(_ reference: XPIF.Reference, parent: URL) {
                let common: XPIF.ReferenceCommon
                switch reference {
                case .file(let file): common = file.common
                case .group(let group): common = group.common
                }
                let base: URL
                switch common.pathBase {
                case .absolute: base = URL(filePath: "/")
                case .groupDir: base = parent
                case .buildSetting("SOURCE_ROOT"): base = URL(filePath: project.projectDir)
                case .buildSetting: return
                }
                let url = base.appending(path: common.path)
                switch reference {
                case .file: files[common.id] = url
                case .group(let group): group.subitems.forEach { collect($0, parent: url) }
                }
            }
            collect(.group(project.mainGroup), parent: URL(filePath: project.projectDir))
            for target in project.targets {
                for phase in target.common.buildPhases {
                    guard case .headers(let phase) = phase else { continue }
                    for file in phase.common.files {
                        guard case .reference(let id) = file.ref, let url = files[id] else { continue }
                        result[target.id.value, default: []].insert(url)
                    }
                }
            }
        }
        return result
    }
}

private extension BuildTargetIdentifier {
    static let xtoolPackageManifest = BuildTargetIdentifier(uri: URI(URL(string: "xtool://package-manifest")!))

    var xtoolTargetGUID: String? {
        URLComponents(url: uri.arbitrarySchemeURL, resolvingAgainstBaseURL: false)?
            .queryItems?.last { $0.name == "targetGUID" }?.value
    }
}

private actor BuildServerClient: QueueBasedMessageHandler {
    let messageHandlingHelper = QueueBasedMessageHandlerHelper(
        signpostLoggingCategory: "underlying-build-server-message-handling",
        createLoggingScope: false
    )
    let messageHandlingQueue = AsyncQueue<BuildServerMessageDependencyTracker>()
    let connection: any LanguageServerProtocol.Connection

    init(connection: any LanguageServerProtocol.Connection) {
        self.connection = connection
    }

    func handle(notification: some NotificationType) async {
        connection.send(notification)
    }

    func handle<Request: RequestType>(
        request: Request,
        id: RequestID,
        reply: @Sendable @escaping (Result<Request.Response, any Error>) -> Void
    ) async {
        await RequestAndReply(request, reply: reply).reply { throw ResponseError.methodNotFound(Request.method) }
    }
}
