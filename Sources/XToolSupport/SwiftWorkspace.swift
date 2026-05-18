import Foundation
import XUtils
import PackLib
import BuildServerProtocol
import LanguageServerProtocol
import LanguageServerProtocolTransport
import Subprocess
import Dependencies

actor SwiftWorkspace {
    private let connection: JSONRPCConnection
    private let buildDirectory: FilePath
    private let outDirectory: FilePath
    private var counter = 0

    struct FileInfo {
        let file: FilePath
        let target: BuildTarget
        let sources: SourcesItem
        let source: SourceItem

        init?(target: BuildTarget, sources: SourcesItem, source: SourceItem) {
            guard let path = FilePath(source.uri.arbitrarySchemeURL) else { return nil }
            self.file = path
            self.target = target
            self.sources = sources
            self.source = source
        }
    }

    private var filesToWatch: [FilePath: [FileInfo]] = [:]
    private var sources: [(BuildTarget, SourcesItem)] {
        didSet { updateFilesToWatch() }
    }
    private var cachedCommands: [FilePath: FrontendCommand] = [:]

    struct FrontendCommand {
        let commandLine: CommandInvocation
        let output: FilePath
        let module: String
    }

    init(
        buildDirectory: FilePath,
        outDirectory: FilePath,
        buildSettings: BuildSettings,
    ) async throws {
        guard let swiftURL = URL(filePath: try await BuildSettings.swiftURL()) else {
            throw Console.Error("Swift URL invalid")
        }

        self.buildDirectory = buildDirectory
        self.outDirectory = outDirectory

        let handler = StreamingMessageHandler()

        let (connection, _) = try JSONRPCConnection.start(
            executable: swiftURL,
            arguments: buildSettings.buildServerArguments,
            name: "xtool",
            protocol: .bspProtocol,
            stderrLoggingCategory: "xtool-error",
            client: handler,
            terminationHandler: { print("Terminated: \($0)") }
        )
        self.connection = connection

        _ = try await connection.send(InitializeBuildRequest(
            displayName: "xtool",
            version: "1.0.0",
            bspVersion: "2.2.0",
            rootUri: .init(URL(filePath: FileManager.default.currentDirectoryPath)),
            capabilities: BuildClientCapabilities(
                languageIds: [.swift, .c, .cpp, .objective_c, .objective_cpp],
            )
        ))

        connection.send(OnBuildInitializedNotification())

        for await case _ as OnBuildTargetDidChangeNotification in handler.notifications { break }

        let result = try await connection.send(WorkspaceBuildTargetsRequest())

        let targets = Dictionary(uniqueKeysWithValues: result.targets.map { ($0.id, $0) })

        let targetInfos = try await connection.send(BuildTargetSourcesRequest(
            targets: result.targets.map(\.id)
        ))
        sources = targetInfos.items.compactMap {
            guard let target = targets[$0.target] else { return nil }
            return (target, $0)
        }

        updateFilesToWatch()
    }

    deinit {
        connection.close()
    }

    func updateFilesToWatch() {
        filesToWatch = Dictionary(
            grouping: sources.flatMap { target, sources in
                sources.sources.compactMap { source in
                    // guard !target.id.uri.stringValue.contains("&targetGUID=PACKAGE-TARGET:") else { return nil }
                    FileInfo(target: target, sources: sources, source: source)
                }
            },
            by: \.file
        )
    }

    func fileDidChange(_ path: FilePath) async throws {
        guard filesToWatch[path] != nil else { return }
        print("Reloading \(path)")
        _ = try await rebuild(path: path)
    }

    @discardableResult
    func rebuild(path: FilePath) async throws -> FilePath {
        let command = try await frontendCommand(for: path)

        try await Subprocess.run(
            .path(FilePath(String(command.commandLine.command))),
            arguments: .init(command.commandLine.arguments.map { String($0) }),
            output: .standardOutput,
            error: .standardError,
        )
        .checkSuccess()

        let sdk = try command.commandLine.value(for: "-sdk")
            .orThrow(Console.Error("Could not find -sdk"))

        let target = try command.commandLine.value(for: "-target")
            .orThrow(Console.Error("Could not find -target"))

        counter += 1

        let outputFile = outDirectory
            .appending("lib\(path.lastComponent!.stem).\(counter).dylib")

        // link
        try await Subprocess.run(
            .path(try await BuildSettings.swiftcURL()),
            arguments: [
                command.output.string,
                "-emit-library",
                "-sdk", sdk, "-target", target,
                "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
                "-o", outputFile.string
            ],
            output: .standardOutput,
            error: .standardError,
        )
        .checkSuccess()

        return outputFile
    }

    func frontendCommand(for path: FilePath) async throws -> FrontendCommand {
        if let cached = cachedCommands[path] {
            return cached
        }

        let targets = filesToWatch[path] ?? []

        let target: FileInfo
        switch targets.count {
        case 0:
            throw Console.Error("No targets for file")
        case 1:
            target = targets[0]
        default:
            print("warning: multiple targets contain this file: \(targets.map(\.target.id.uri))")
            target = targets[0]
        }

        guard let fileURL = URL(filePath: path)?.absoluteURL, let lastComponent = path.lastComponent else {
            throw Console.Error("Bad file path \(path.string)")
        }

        let options = try await connection.send(TextDocumentSourceKitOptionsRequest(
            textDocument: .init(target.source.uri),
            target: target.target.id,
            language: .swift,
        ))
        .orThrow(Console.Error("No options"))

        guard let moduleNameIndex = options.compilerArguments.firstIndex(of: "-module-name"),
           moduleNameIndex < options.compilerArguments.count - 2 else {
            throw Console.Error("Could not determine module name for file at \(path)")
        }
        let moduleName = options.compilerArguments[moduleNameIndex + 1]
        let moduleBuildDirectory = buildDirectory.appending(moduleName)
        let moduleBuildDirectoryURL = try URL(filePath: moduleBuildDirectory).orThrow(Console.Error("Bad module name"))
        try? FileManager.default.createDirectory(at: moduleBuildDirectoryURL, withIntermediateDirectories: true)

        let swiftcOutput = try await Subprocess.run(
            .path(try await BuildSettings.swiftcURL()),
            arguments: .init(
                ["-c", "-driver-print-jobs"]
                + options.compilerArguments
                + ["-working-directory", moduleBuildDirectory.string]
            ),
            output: .string(limit: .max),
            error: .standardError
        ).checkSuccess()

        let frontendCommands = (swiftcOutput.standardOutput ?? "").split(separator: "\n")
        guard let invocation = frontendCommands.lazy.compactMap({ line -> CommandInvocation? in
            guard let invocation = CommandInvocation(line) else { return nil }
            guard invocation.value(for: "-primary-file") == fileURL.path else { return nil }
            return invocation
        }).first else { throw Console.Error("Could not find frontend command") }

        let command = FrontendCommand(
            commandLine: invocation,
            output: moduleBuildDirectory.appending("\(lastComponent.stem).o"),
            module: moduleName,
        )
        cachedCommands[path] = command
        return command
    }

    private final class StreamingMessageHandler: MessageHandler {
        private let (_notifications, onNotification) = AsyncStream<NotificationType>.makeStream()

        var notifications: AsyncStream<NotificationType> { _notifications }

        deinit { onNotification.finish() }

        func handle(_ notification: some NotificationType) {
            onNotification.yield(notification)
        }

        func handle<Request: RequestType>(
            _ request: Request,
            id: LanguageServerProtocol.RequestID,
            reply: @escaping @Sendable (LanguageServerProtocol.LSPResult<Request.Response>) -> Void
        ) {
            fatalError("Can't handle request \(Request.method)")
        }
    }
}

struct CommandInvocation {
    var command: String
    var arguments: [String]

    init?(_ string: some StringProtocol) {
        guard let all = try? CommandParser.parse(string), !all.isEmpty else { return nil }
        command = all[0]
        arguments = Array(all.dropFirst())
    }

    func value(for option: some StringProtocol) -> String? {
        guard let optionIndex = arguments.firstIndex(where: { $0 == option }) else { return nil }
        guard optionIndex < arguments.count - 2 else { return nil }
        return arguments[optionIndex + 1]
    }
}

enum CommandParser {
    enum Errors: Error, Hashable {
        case unclosedQuote
        case unpairedEscape
    }

    static func parse(_ string: some StringProtocol) throws -> [String] {
        try sequence(
            state: (
                current: string[...],
                isInsideQuote: false,
            )
        ) { state -> Token? in
            while !state.current.isEmpty {
                switch state.current.removeFirst() {
                case "'":
                    state.isInsideQuote.toggle()
                case "\\" where !state.isInsideQuote:
                    guard !state.current.isEmpty else { return .error(.unpairedEscape) }
                    let actual = state.current.removeFirst()
                    return .value(actual)
                case " " where !state.isInsideQuote:
                    return .sentinelSpace
                case let value:
                    return .value(value)
                }
            }
            guard !state.isInsideQuote else {
                state.isInsideQuote = false
                return .error(.unclosedQuote)
            }
            return nil
        }
        .lazy
        .split(separator: .sentinelSpace)
        .map {
            let characters = try $0.compactMap { token -> Character? in
                switch token {
                case .sentinelSpace: nil
                case .error(let error): throw error
                case .value(let value): value
                }
            }
            return String(characters)
        }
    }

    private enum Token: Hashable {
        case sentinelSpace
        case value(Character)
        case error(Errors)
    }
}
