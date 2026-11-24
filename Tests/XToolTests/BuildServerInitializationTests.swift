import BuildServerProtocol
import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import LanguageServerProtocol
import LanguageServerProtocolTransport
import Testing
import XUtils
@testable import XToolSupport

struct BuildServerInitializationTests {
    @Test
    func uninitializedServerDoesNotCreateACoordinatorAndCanExit() async throws {
        let client = LocalConnection(receiverName: "test client")
        defer { client.close() }
        let exits = LockIsolated<[Int]>([])
        let server = XToolBuildServer(triple: "arm64-apple-ios", connectionToClient: client) { code in
            exits.withValue { $0.append(code) }
        }
        defer { await server.close() }
        let connection = LocalConnection(receiverName: "test server", handler: server)
        defer { connection.close() }
        await server.handle(notification: OnBuildInitializedNotification())
        do {
            _ = try await connection.send(WorkspaceBuildTargetsRequest())
            Issue.record("Expected an uninitialized-server error")
        } catch let error as ResponseError {
            expectNoDifference(error.code, .serverNotInitialized)
        }
        await server.handle(notification: OnBuildExitNotification())
        expectNoDifference(exits.value, [0])
        await server.close()
    }

    @Test
    func rejectsNonFileRootURI() async throws {
        let client = LocalConnection(receiverName: "test client")
        defer { client.close() }
        let server = XToolBuildServer(triple: "arm64-apple-ios", connectionToClient: client, exitHandler: { _ in })
        defer { await server.close() }
        let connection = LocalConnection(receiverName: "test server", handler: server)
        defer { connection.close() }
        do {
            _ = try await connection.send(initialize(URL(string: "https://example.com/project")!))
            Issue.record("Expected an invalid rootUri error")
        } catch let error as ResponseError {
            expectNoDifference(error.code, .invalidParams)
        }
    }

    #if os(macOS)
    @Test(.requiresXcode, .timeLimit(.minutes(2)))
    func rootURISelectsProjectAndBuildArenaWithoutChangingWorkingDirectory() async throws {
        let temporary = try TemporaryDirectory(name: "BSP Root URI")
        let originalDirectory = FileManager.default.currentDirectoryPath
        try await withDependencies {
            $0.out = .liveValue
            $0.shutdownRegistry = .liveValue
        } operation: {
            for name in ["First", "Second"] {
                let root = temporary.url.appending(path: "\(name) Package é").resolvingSymlinksInPath()
                try makePackage(name: name, at: root)
                let client = LocalConnection(receiverName: "test client")
                defer { client.close() }
                let server = XToolBuildServer(triple: "arm64-apple-ios", connectionToClient: client, exitHandler: { _ in })
                defer { await server.close() }
                let connection = LocalConnection(receiverName: "test server", handler: server)
                defer { connection.close() }

                let response = try await connection.send(initialize(root))
                expectNoDifference(response.displayName, "xtool Build Server")
                await server.handle(notification: OnBuildInitializedNotification())
                _ = try await connection.send(WorkspaceWaitForBuildSystemUpdatesRequest())
                let targets = try await connection.send(WorkspaceBuildTargetsRequest())
                #expect(targets.targets.contains { $0.displayName == name })
                let manifest = BuildTargetIdentifier(uri: URI(URL(string: "xtool://package-manifest")!))
                let sources = try await connection.send(BuildTargetSourcesRequest(targets: [manifest]))
                expectNoDifference(
                    sources.items.flatMap(\.sources).map(\.uri), [DocumentURI(root.appending(path: "Package.swift"))]
                )
                let options = try await connection.send(TextDocumentSourceKitOptionsRequest(
                    textDocument: TextDocumentIdentifier(DocumentURI(root.appending(path: "Package.swift"))),
                    target: manifest,
                    language: .swift
                ))
                expectNoDifference(options?.workingDirectory, root.path)

                let indexData = try #require(SourceKitInitializeBuildResponseData(fromLSPAny: response.data))
                #expect(indexData.indexStorePath?.hasPrefix(root.path + "/") == true)
                await #expect(throws: ResponseError.self) {
                    try await connection.send(initialize(root))
                }
                _ = try await connection.send(BuildShutdownRequest())
                expectNoDifference(FileManager.default.currentDirectoryPath, originalDirectory)
            }
        }
    }

    private func makePackage(name: String, at root: URL) throws {
        let sources = root.appending(path: "Sources/\(name)")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("public struct Example {}\n".utf8).write(to: sources.appending(path: "Example.swift"))
        try Data("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "\(name)",
            platforms: [.iOS(.v17)],
            products: [.library(name: "\(name)", targets: ["\(name)"])],
            targets: [.target(name: "\(name)")]
        )
        """.utf8).write(to: root.appending(path: "Package.swift"))
        try Data("version: 1\norgID: org.example\nskipLSP: true\n".utf8).write(to: root.appending(path: "xtool.yml"))
    }
    #endif

    private func initialize(_ root: URL) -> InitializeBuildRequest {
        InitializeBuildRequest(
            displayName: "Test", version: "1.0", bspVersion: "2.2.0", rootUri: URI(root),
            capabilities: BuildClientCapabilities(languageIds: [.swift])
        )
    }
}
