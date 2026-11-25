import Foundation
import Dependencies
import HTTPTypesFoundation
import XKit
import XUtils

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
            v\(version)/OpenAppleMacrosServer-\(arch.rawValue).tar.gz
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

        This error is not caused by your Xcode.xip. xtool fetches the \(artifact.name) \
        separately from:
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
    /// Wait before the first retry when the server sends no `Retry-After`; doubled per attempt.
    var retryDelay: Duration
    /// Upper bound on a server's `Retry-After`, so a broken value cannot stall setup.
    var maxRetryAfter: Duration
    var sleep: @Sendable (Duration) async throws -> Void

    init(
        maxAttempts: Int = 3,
        retryDelay: Duration = .milliseconds(250),
        maxRetryAfter: Duration = .seconds(60),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.maxAttempts = maxAttempts
        self.retryDelay = retryDelay
        self.maxRetryAfter = maxRetryAfter
        self.sleep = sleep
    }

    /// An HTTP failure plus the server's `Retry-After`, kept out of the public error.
    private struct StatusFailure: Error {
        var error: SDKGitHubDownloadError
        var retryAfter: Duration?
    }

    func body(for artifact: SDKGitHubArtifact) async throws -> Data {
        precondition(maxAttempts >= 1, "maxAttempts must be at least 1")
        var lastError: SDKGitHubDownloadError?
        for attempt in 1...maxAttempts {
            let error: SDKGitHubDownloadError
            var retryAfter: Duration?
            do {
                return try await fetch(artifact)
            } catch let thrown as CancellationError {
                throw thrown
            } catch let thrown as StatusFailure {
                error = thrown.error
                retryAfter = thrown.retryAfter
            } catch let thrown as SDKGitHubDownloadError {
                error = thrown
            }
            lastError = error
            guard error.isRetryable, attempt < maxAttempts else { throw error }
            try await sleep(delay(beforeRetry: attempt, retryAfter: retryAfter))
        }
        throw lastError!
    }

    /// The server's `Retry-After` capped at `maxRetryAfter`, else `retryDelay` doubled per attempt.
    func delay(beforeRetry attempt: Int, retryAfter: Duration?) -> Duration {
        if let retryAfter {
            return min(max(retryAfter, .zero), maxRetryAfter)
        }
        return retryDelay * (1 << min(attempt - 1, 16))
    }

    /// Parses `Retry-After` as delay-seconds or an HTTP-date. A malformed value is nil.
    static func retryAfter(_ value: String?, now: Date = Date()) -> Duration? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) {
            return seconds >= 0 ? .seconds(seconds) : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return .seconds(max(0, Int(date.timeIntervalSince(now).rounded(.up))))
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
            throw StatusFailure(
                error: .httpStatus(artifact, response.status.code),
                retryAfter: Self.retryAfter(response.headerFields[.retryAfter])
            )
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
        var reportedProgress = false
        do {
            for try await chunk in body {
                data.append(contentsOf: chunk)
                if let total, total > 0 {
                    reportProgress(artifact, written: Int64(data.count), total: total)
                    reportedProgress = true
                }
            }
        } catch {
            // Progress is printed with no terminator, so end that line before the error.
            if reportedProgress { d.out.print() }
            if error is CancellationError { throw error }
            throw SDKGitHubDownloadError.network(artifact, String(describing: error))
        }
        // A body that ends cleanly but short of its declared length is a truncated download.
        if let total, Int64(data.count) != total {
            if reportedProgress { d.out.print() }
            throw SDKGitHubDownloadError.network(
                artifact, "body ended after \(data.count) of \(total) bytes"
            )
        }
        // Some transports hand back an empty body rather than nil for a zero-byte response.
        guard !data.isEmpty else { throw SDKGitHubDownloadError.emptyBody(artifact) }
        return data
    }

    private func reportProgress(_ artifact: SDKGitHubArtifact, written: Int64, total: Int64) {
        let progress = Int(Double(written) / Double(total) * 100)
        d.out.print("\r[\(artifact.progressLabel)] \(progress)%", terminator: "", flush: true)
    }
}
