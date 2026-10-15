import Foundation
import Dependencies
import HTTPTypesFoundation
import XKit

struct SDKGitHubArtifact: Equatable, Sendable {
    var name: String
    var progressLabel: String
    var url: URL

    static func toolset(
        arch: SDKBuilder.Arch,
        version: String = SDKBuilder.darwinToolsVersion
    ) -> Self {
        Self(
            name: "Darwin toolset",
            progressLabel: "Downloading toolset",
            url: URL(string: """
            https://github.com/xtool-org/darwin-tools-linux-llvm/releases/download/\
            v\(version)/toolset-\(arch.rawValue).tar.gz
            """)!
        )
    }

    static func openAppleMacros(
        arch: SDKBuilder.Arch,
        version: String = SDKBuilder.oamVersion
    ) -> Self {
        Self(
            name: "OpenAppleMacros",
            progressLabel: "Downloading OpenAppleMacros",
            url: URL(string: """
            https://github.com/xtool-org/OpenAppleMacros/releases/download/\
            v\(version)/OpenAppleMacrosServer-\(arch.rawValue)
            """)!
        )
    }
}

enum SDKGitHubDownloadError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case httpStatus(SDKGitHubArtifact, Int)
    case emptyBody(SDKGitHubArtifact)
    case network(SDKGitHubArtifact, String)

    var artifact: SDKGitHubArtifact {
        switch self {
        case .httpStatus(let artifact, _), .emptyBody(let artifact), .network(let artifact, _):
            artifact
        }
    }

    var isRetryable: Bool {
        switch self {
        case .httpStatus(_, let status):
            status == 429 || (500...599).contains(status)
        case .emptyBody:
            false
        case .network:
            true
        }
    }

    var description: String {
        let detail: String
        switch self {
        case .httpStatus(_, let status):
            detail = "GitHub responded with HTTP \(status)."
        case .emptyBody:
            detail = "GitHub returned an empty response body."
        case .network(_, let message):
            detail = "Network error: \(message)"
        }
        return """
        Failed to download the \(artifact.name) from GitHub.

        This error is not caused by your Xcode.xip. xtool fetches the Darwin \
        toolchain separately from:
          \(artifact.url)

        \(detail)

        Check your network connection and GitHub availability, then retry \
        `xtool sdk install`. You do not need to re-download Xcode.
        """
    }

    var errorDescription: String? { description }
}

struct SDKGitHubDownloader: Sendable {
    var maxAttempts: Int
    var retryDelay: Duration
    var sleep: @Sendable (Duration) async throws -> Void

    init(
        maxAttempts: Int = 3,
        retryDelay: Duration = .milliseconds(250),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.maxAttempts = maxAttempts
        self.retryDelay = retryDelay
        self.sleep = sleep
    }

    func body(for artifact: SDKGitHubArtifact) async throws -> Data {
        precondition(maxAttempts >= 1, "maxAttempts must be at least 1")
        var lastError: SDKGitHubDownloadError?
        for attempt in 1...maxAttempts {
            do {
                return try await fetch(artifact)
            } catch let error as CancellationError {
                throw error
            } catch let error as SDKGitHubDownloadError {
                lastError = error
                guard error.isRetryable, attempt < maxAttempts else { throw error }
                try await sleep(retryDelay)
            }
        }
        throw lastError!
    }

    private func fetch(_ artifact: SDKGitHubArtifact) async throws -> Data {
        @Dependency(\.httpClient) var httpClient
        let response: HTTPResponse
        let body: HTTPBody?
        do {
            (response, body) = try await httpClient.send(HTTPRequest(url: artifact.url))
        } catch let error as CancellationError {
            throw error
        } catch {
            throw SDKGitHubDownloadError.network(artifact, String(describing: error))
        }
        guard response.status == .ok else {
            throw SDKGitHubDownloadError.httpStatus(artifact, response.status.code)
        }
        guard let body else {
            throw SDKGitHubDownloadError.emptyBody(artifact)
        }
        return try await consume(body, artifact: artifact)
    }

    private func consume(_ body: HTTPBody, artifact: SDKGitHubArtifact) async throws -> Data {
        let total: Int64? = switch body.length {
        case .known(let known): known
        case .unknown: nil
        }
        var data = Data()
        do {
            for try await chunk in body {
                data.append(contentsOf: chunk)
                reportProgress(artifact, written: Int64(data.count), total: total)
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            throw SDKGitHubDownloadError.network(artifact, String(describing: error))
        }
        return data
    }

    private func reportProgress(_ artifact: SDKGitHubArtifact, written: Int64, total: Int64?) {
        guard let total else { return }
        let progress = Int(Double(written) / Double(total) * 100)
        print("\r[\(artifact.progressLabel)] \(progress)%", terminator: "")
        fflush(stdoutSafe)
    }
}
