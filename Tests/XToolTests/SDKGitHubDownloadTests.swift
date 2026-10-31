import Foundation
import Testing
import Dependencies
import HTTPTypes
import OpenAPIRuntime
import XKit
import XUtils
@testable import XToolSupport

private struct ScriptedHTTPClient: HTTPClientProtocol, ClientTransport {
    var asOpenAPITransport: ClientTransport { self }
    var handler: @Sendable (HTTPRequest) async throws -> (HTTPResponse, HTTPBody?)

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        try await handler(request)
    }

    func withEphemeralClient<T>(
        perform: (any HTTPClientProtocol) async throws -> T
    ) async throws -> T {
        try await perform(self)
    }

    func makeWebSocket(url: URL) async throws -> any WebSocketSession {
        struct Unused: Error {}
        throw Unused()
    }
}

private final class AttemptBox: @unchecked Sendable {
    var count = 0
}

private final class OutputBox: @unchecked Sendable {
    var data = Data()
    var text: String { String(decoding: data, as: UTF8.self) }
}

private struct MidBodyFailure: Error, CustomStringConvertible {
    var description: String { "connection reset by peer" }
}

private func bodyThatFailsMidway(_ prefix: Data, length: HTTPBody.Length = .unknown) -> HTTPBody {
    let stream = AsyncThrowingStream<HTTPBody.ByteChunk, any Error> { continuation in
        continuation.yield(Array(prefix)[...])
        continuation.finish(throwing: MidBodyFailure())
    }
    return HTTPBody(stream, length: length)
}

@Test func sdkGitHubArtifactURLsMatchPublishedReleases() {
    let toolset = SDKGitHubArtifact.toolset(arch: .x86_64, version: "1.1.0")
    #expect(toolset.name == "Darwin toolset")
    #expect(toolset.url.absoluteString == """
    https://github.com/xtool-org/darwin-tools-linux-llvm/releases/download/v1.1.0/toolset-x86_64.tar.gz
    """)

    let macros = SDKGitHubArtifact.openAppleMacros(arch: .aarch64, version: "1.3.0")
    #expect(macros.name == "OpenAppleMacros")
    #expect(macros.url.absoluteString == """
    https://github.com/xtool-org/OpenAppleMacros/releases/download/v1.3.0/OpenAppleMacrosServer-aarch64.tar.gz
    """)
}

@Test func sdkGitHubDownloadExplainsGitHubFailureIsNotTheXIP() {
    let artifact = SDKGitHubArtifact.toolset(arch: .x86_64)
    let error = SDKGitHubDownloadError.httpStatus(artifact, 502)
    #expect(error.description.contains("not caused by your Xcode.xip"))
    #expect(error.description.contains("Darwin toolset"))
    #expect(error.description.contains(artifact.url.absoluteString))
    #expect(error.description.contains("HTTP 502"))
    #expect(error.description.contains("You do not need to re-download Xcode"))
    #expect(error.description.contains("xtool fetches the Darwin toolset separately from:"))
    #expect(error.isRetryable)

    let missing = SDKGitHubDownloadError.httpStatus(artifact, 404)
    #expect(!missing.isRetryable)
    #expect(!SDKGitHubDownloadError.emptyBody(artifact).isRetryable)
    #expect(SDKGitHubDownloadError.network(artifact, "connection reset").isRetryable)
}

@Test func sdkGitHubDownloadErrorNamesTheArtifactThatFailed() {
    let artifact = SDKGitHubArtifact.openAppleMacros(arch: .x86_64)
    let error = SDKGitHubDownloadError.httpStatus(artifact, 502)
    #expect(error.description.contains("xtool fetches the OpenAppleMacros separately from:"))
    #expect(!error.description.contains("toolchain"))
}

@Test(arguments: [false, true])
func sdkGitHubDownloadTreatsZeroByteBodyAsEmpty(yieldsEmptyChunk: Bool) async throws {
    let artifact = SDKGitHubArtifact.toolset(arch: .x86_64)
    let client = ScriptedHTTPClient { _ in
        (HTTPResponse(status: .ok), yieldsEmptyChunk ? HTTPBody(Data()) : HTTPBody())
    }
    let downloader = SDKGitHubDownloader(maxAttempts: 3, retryDelay: .zero, sleep: { _ in })

    await withDependencies {
        $0.httpClient = client
        $0.out.write = { _, _, _ in }
    } operation: {
        await #expect(throws: SDKGitHubDownloadError.emptyBody(artifact)) {
            _ = try await downloader.body(for: artifact)
        }
    }
}

@Test func sdkGitHubDownloadEndsProgressLineWhenBodyFails() async throws {
    let output = OutputBox()
    let artifact = SDKGitHubArtifact.toolset(arch: .x86_64)
    let body = bodyThatFailsMidway(Data("half".utf8), length: .known(8))
    let client = ScriptedHTTPClient { _ in (HTTPResponse(status: .ok), body) }
    let downloader = SDKGitHubDownloader(maxAttempts: 1, retryDelay: .zero, sleep: { _ in })

    await withDependencies {
        $0.httpClient = client
        $0.out.write = { data, _, _ in output.data.append(data) }
    } operation: {
        await #expect(throws: SDKGitHubDownloadError.self) {
            _ = try await downloader.body(for: artifact)
        }
    }
    #expect(output.text == "\r[Downloading toolset] 50%\n")
}

@Test func sdkGitHubDownloadPrintsNothingWhenNoProgressWasReported() async throws {
    let output = OutputBox()
    let artifact = SDKGitHubArtifact.toolset(arch: .x86_64)
    let client = ScriptedHTTPClient { _ in
        (HTTPResponse(status: .ok), bodyThatFailsMidway(Data("half".utf8)))
    }
    let downloader = SDKGitHubDownloader(maxAttempts: 1, retryDelay: .zero, sleep: { _ in })

    await withDependencies {
        $0.httpClient = client
        $0.out.write = { data, _, _ in output.data.append(data) }
    } operation: {
        await #expect(throws: SDKGitHubDownloadError.self) {
            _ = try await downloader.body(for: artifact)
        }
    }
    #expect(output.data.isEmpty)
}

@Test func sdkGitHubDownloadMapsHTTPError() async throws {
    let artifact = SDKGitHubArtifact.openAppleMacros(arch: .x86_64)
    let client = ScriptedHTTPClient { _ in
        (HTTPResponse(status: .notFound), nil)
    }
    let downloader = SDKGitHubDownloader(maxAttempts: 3, retryDelay: .zero, sleep: { _ in })

    await withDependencies {
        $0.httpClient = client
    } operation: {
        await #expect(throws: SDKGitHubDownloadError.httpStatus(artifact, 404)) {
            _ = try await downloader.body(for: artifact)
        }
    }
}

@Test func sdkGitHubDownloadDoesNotRetryClientErrors() async throws {
    let attempts = AttemptBox()
    let artifact = SDKGitHubArtifact.toolset(arch: .aarch64)
    let client = ScriptedHTTPClient { _ in
        attempts.count += 1
        return (HTTPResponse(status: .notFound), nil)
    }
    let downloader = SDKGitHubDownloader(maxAttempts: 3, retryDelay: .zero, sleep: { _ in })

    await withDependencies {
        $0.httpClient = client
    } operation: {
        await #expect(throws: SDKGitHubDownloadError.self) {
            _ = try await downloader.body(for: artifact)
        }
    }
    #expect(attempts.count == 1)
}

@Test func sdkGitHubDownloadRetriesServerErrorsThenSucceeds() async throws {
    let attempts = AttemptBox()
    let sleeps = AttemptBox()
    let artifact = SDKGitHubArtifact.toolset(arch: .x86_64)
    let payload = Data("toolset".utf8)
    let client = ScriptedHTTPClient { _ in
        attempts.count += 1
        if attempts.count < 3 {
            return (HTTPResponse(status: .init(code: 503, reasonPhrase: "Unavailable")), nil)
        }
        return (HTTPResponse(status: .ok), HTTPBody(payload))
    }
    let downloader = SDKGitHubDownloader(
        maxAttempts: 3,
        retryDelay: .milliseconds(1),
        sleep: { _ in sleeps.count += 1 }
    )

    let data = try await withDependencies {
        $0.httpClient = client
        $0.out.write = { _, _, _ in }
    } operation: {
        try await downloader.body(for: artifact)
    }
    #expect(attempts.count == 3)
    #expect(sleeps.count == 2)
    #expect(data == payload)
}

@Test func sdkGitHubDownloadRetriesMidBodyFailureAndDropsPartialBytes() async throws {
    let attempts = AttemptBox()
    let sleeps = AttemptBox()
    let artifact = SDKGitHubArtifact.toolset(arch: .x86_64)
    let partial = Data("partial-from-attempt-1".utf8)
    let complete = Data("only-attempt-2".utf8)
    let client = ScriptedHTTPClient { _ in
        attempts.count += 1
        if attempts.count == 1 {
            return (HTTPResponse(status: .ok), bodyThatFailsMidway(partial))
        }
        return (HTTPResponse(status: .ok), HTTPBody(complete))
    }
    let downloader = SDKGitHubDownloader(
        maxAttempts: 3,
        retryDelay: .milliseconds(1),
        sleep: { _ in sleeps.count += 1 }
    )

    let data = try await withDependencies {
        $0.httpClient = client
        $0.out.write = { _, _, _ in }
    } operation: {
        try await downloader.body(for: artifact)
    }
    #expect(attempts.count == 2)
    #expect(sleeps.count == 1)
    #expect(data == complete)
}

@Test func sdkGitHubDownloadFailsWithArtifactErrorWhenBodyAlwaysFails() async throws {
    let attempts = AttemptBox()
    let sleeps = AttemptBox()
    let artifact = SDKGitHubArtifact.openAppleMacros(arch: .aarch64)
    let client = ScriptedHTTPClient { _ in
        attempts.count += 1
        return (HTTPResponse(status: .ok), bodyThatFailsMidway(Data("partial".utf8)))
    }
    let downloader = SDKGitHubDownloader(
        maxAttempts: 3,
        retryDelay: .zero,
        sleep: { _ in sleeps.count += 1 }
    )

    await withDependencies {
        $0.httpClient = client
    } operation: {
        await #expect(throws: SDKGitHubDownloadError.network(artifact, "connection reset by peer")) {
            _ = try await downloader.body(for: artifact)
        }
    }
    #expect(attempts.count == 3)
    #expect(sleeps.count == 2)
    let surfaced = SDKGitHubDownloadError.network(artifact, "connection reset by peer")
    #expect(surfaced.description.contains(artifact.name))
    #expect(surfaced.description.contains(artifact.url.absoluteString))
}

@Test func sdkGitHubDownloadWrapsTransportFailures() async throws {
    struct Boom: Error, CustomStringConvertible {
        var description: String { "connection timed out" }
    }
    let artifact = SDKGitHubArtifact.openAppleMacros(arch: .x86_64)
    let client = ScriptedHTTPClient { _ in throw Boom() }
    let downloader = SDKGitHubDownloader(maxAttempts: 1, retryDelay: .zero, sleep: { _ in })

    await withDependencies {
        $0.httpClient = client
    } operation: {
        await #expect(throws: SDKGitHubDownloadError.network(artifact, "connection timed out")) {
            _ = try await downloader.body(for: artifact)
        }
    }
}
