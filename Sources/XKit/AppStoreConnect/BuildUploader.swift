import Foundation
import DeveloperAPI
import Dependencies
import HTTPTypes
import HTTPTypesFoundation
import OpenAPIRuntime

/// Uploads a build to App Store Connect (and so to TestFlight) with the public
/// [Build Uploads](https://developer.apple.com/documentation/appstoreconnectapi/build-uploads) API.
///
/// The flow is: create a build upload, reserve the file, send the file in parts to the
/// pre-signed URLs that Apple returns, commit the file, and then Apple processes the build.
public struct BuildUploader: Sendable {
    public struct Configuration: Sendable {
        /// The maximum number of tries for a request that is safe to repeat.
        public var maxAttempts = 4
        /// The delay before the first retry. It doubles at every retry.
        public var retryDelay: Duration = .seconds(1)
        /// The delay between the first status checks. It grows up to `maxPollInterval`.
        public var pollInterval: Duration = .seconds(5)
        public var maxPollInterval: Duration = .seconds(30)
        /// How long to wait for Apple to process the build before giving up.
        public var timeout: Duration = .seconds(30 * 60)
        /// The number of parts that are sent at the same time.
        public var maxConcurrentParts = 4

        public init() {}
    }

    public enum Event: Sendable, Hashable {
        case createdUpload(id: String)
        case reservedFile(parts: Int)
        case uploadedPart(completed: Int, total: Int)
        case committedFile
        /// App Store Connect's own name for the state, such as `PROCESSING`.
        case processing(state: String)
    }

    public struct Result: Sendable, Hashable {
        public var uploadID: String
        /// `COMPLETE` once Apple has accepted the build, otherwise the last state that was seen.
        public var state: String
        public var warnings: [String]
        public var infos: [String]
    }

    public enum Error: Swift.Error, LocalizedError, CustomStringConvertible {
        /// The App Store Connect API answered with a non-2xx status.
        case http(status: Int, details: String)
        case appNotFound(bundleID: String)
        case malformedResponse(String)
        case unreadablePart(offset: Int64, length: Int64)
        case partUploadFailed(partNumber: Int64?, underlying: Swift.Error)
        /// Apple processed the build and rejected it. Each entry is `code: description`.
        case processingFailed(uploadID: String, errors: [String])
        case timedOut(uploadID: String)

        public var description: String {
            switch self {
            case .http(let status, let details):
                "App Store Connect answered HTTP \(status)\(details.isEmpty ? "" : ": \(details)")"
            case .appNotFound(let bundleID):
                "No app with the bundle ID \(bundleID) was found in App Store Connect. "
                    + "Create it there first, or pass its ID with --app-id."
            case .malformedResponse(let what):
                "Unexpected response from App Store Connect: \(what)."
            case .unreadablePart(let offset, let length):
                "Could not read \(length) bytes at offset \(offset) of the file."
            case .partUploadFailed(let partNumber, let underlying):
                "Uploading part \(partNumber.map(String.init) ?? "?") failed: \(underlying)"
            case .processingFailed(let uploadID, let errors):
                "App Store Connect rejected the build (upload \(uploadID)):\n"
                    + errors.map { "- \($0)" }.joined(separator: "\n")
            case .timedOut(let uploadID):
                "Timed out waiting for App Store Connect to process upload \(uploadID). "
                    + "It may still complete: check App Store Connect."
            }
        }

        public var errorDescription: String? { description }
    }

    /// How long before its expiration a pre-signed URL is considered stale.
    static let urlRefreshMargin: TimeInterval = 60

    private let client: DeveloperAPIClient
    private let auth: DeveloperAPIASCAuthMiddleware
    private let transport: any ClientTransport
    private let baseURL: URL
    private let configuration: Configuration
    @Dependency(\.httpClient) private var httpClient
    @Dependency(\.continuousClock) private var clock
    @Dependency(\.date) private var date

    public init(key: ASCKey, configuration: Configuration = .init()) {
        @Dependency(\.httpClient) var httpClient
        self.configuration = configuration
        self.auth = DeveloperAPIASCAuthMiddleware(key: key)
        self.transport = httpClient.asOpenAPITransport
        // swiftlint:disable:next force_try
        self.baseURL = try! Servers.Server1.url()
        self.client = DeveloperAPIClient(
            serverURL: baseURL,
            configuration: .init(dateTranscoder: LenientISO8601DateTranscoder()),
            transport: transport,
            middlewares: [auth, HTTPStatusMiddleware(), LoggingMiddleware()]
        )
    }

    // MARK: - Resolving the app

    /// Finds the App Store Connect app ID for a bundle ID.
    public func resolveApp(bundleID: String) async throws -> String {
        // `GET /v1/apps` is not part of the generated client: its schemas (an app and everything
        // that can be included with it) would add ~10k lines for one filtered lookup. So this request
        // is made by hand, through the same authentication and error handling as the generated ones.
        struct Apps: Decodable {
            struct App: Decodable {
                struct Attributes: Decodable { var bundleId: String? }
                var id: String
                var attributes: Attributes?
            }
            var data: [App]
        }
        let query = bundleID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._")))
            ?? bundleID
        let request = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: baseURL.host,
            path: "/v1/apps?filter%5BbundleId%5D=\(query)&fields%5Bapps%5D=bundleId&limit=200"
        )
        let data = try await retrying {
            try await get(request)
        }
        let apps = try JSONDecoder().decode(Apps.self, from: data)
        // the filter is not guaranteed to be an exact match
        guard let app = apps.data.first(where: { $0.attributes?.bundleId == bundleID }) else {
            throw Error.appNotFound(bundleID: bundleID)
        }
        return app.id
    }

    private func get(_ request: HTTPRequest) async throws -> Data {
        let transport = transport
        let (_, body) = try await auth.intercept(
            request, body: nil, baseURL: baseURL, operationID: "apps_getCollection"
        ) { request, body, baseURL in
            try await HTTPStatusMiddleware().intercept(
                request, body: body, baseURL: baseURL, operationID: "apps_getCollection"
            ) { request, body, baseURL in
                try await transport.send(request, body: body, baseURL: baseURL, operationID: "apps_getCollection")
            }
        }
        guard let body else { return Data() }
        return try await Data(collecting: body, upTo: 10 << 20)
    }

    // MARK: - Uploading

    /// Uploads `ipa` as a new build of the app `appID`.
    ///
    /// - Parameter wait: Whether to wait for Apple to finish processing the build. If it's `false`
    ///   the returned state is whatever Apple reported right after the upload.
    public func upload(
        ipa: URL,
        info: IPAInfo,
        appID: String,
        wait: Bool = true,
        onEvent: (Event) -> Void = { _ in }
    ) async throws -> Result {
        guard let fileSize = try FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? NSNumber else {
            throw Error.malformedResponse("cannot read the size of \(ipa.lastPathComponent)")
        }

        let uploadID = try await createUpload(info: info, appID: appID)
        onEvent(.createdUpload(id: uploadID))

        let fileID: String
        do {
            let reservation = try await reserveFile(
                uploadID: uploadID, name: ipa.lastPathComponent, size: fileSize.int64Value
            )
            fileID = reservation.id
            onEvent(.reservedFile(parts: reservation.operations.count))
            try await send(ipa, operations: reservation.operations, fileID: fileID, onEvent: onEvent)
        } catch {
            // don't leave a dangling reservation behind
            if !(error is CancellationError) {
                _ = try? await client.buildUploadsDeleteInstance(path: .init(id: uploadID))
            }
            throw error
        }

        // Not covered by the cleanup above: if the commit's outcome is unknown, the build may well
        // be processing and deleting the upload would throw it away.
        try await commit(fileID: fileID)
        onEvent(.committedFile)

        if wait {
            return try await waitForProcessing(uploadID: uploadID, onEvent: onEvent)
        } else {
            return try await status(of: uploadID)
        }
    }

    private func createUpload(info: IPAInfo, appID: String) async throws -> String {
        // not retried: a lost response could otherwise leave two uploads for the same build
        let body = Components.Schemas.BuildUploadCreateRequest(data: .init(
            _type: .buildUploads,
            attributes: .init(
                cfBundleShortVersionString: info.version,
                cfBundleVersion: info.build,
                platform: .init(value1: .init(rawValue: info.platform), value2: info.platform)
            ),
            relationships: .init(app: .init(data: .init(_type: .apps, id: appID)))
        ))
        return try await call { try await client.buildUploadsCreateInstance(body: .json(body)).created.body.json.data.id }
    }

    private func reserveFile(
        uploadID: String,
        name: String,
        size: Int64
    ) async throws -> (id: String, operations: [Components.Schemas.DeliveryFileUploadOperation]) {
        let body = Components.Schemas.BuildUploadFileCreateRequest(data: .init(
            _type: .buildUploadFiles,
            attributes: .init(
                assetType: .init(value1: .asset),
                fileName: name,
                fileSize: size,
                uti: .init(value1: .com_apple_ipa)
            ),
            relationships: .init(buildUpload: .init(data: .init(_type: .buildUploads, id: uploadID)))
        ))
        let file = try await call { try await client.buildUploadFilesCreateInstance(body: .json(body)).created.body.json.data }
        guard let operations = file.attributes?.uploadOperations, !operations.isEmpty else {
            throw Error.malformedResponse("the reservation has no upload operations")
        }
        return (file.id, operations)
    }

    private func send(
        _ ipa: URL,
        operations: [Components.Schemas.DeliveryFileUploadOperation],
        fileID: String,
        onEvent: (Event) -> Void
    ) async throws {
        var completed = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            var pending = operations.makeIterator()
            var running = 0

            func startNext() -> Bool {
                guard let operation = pending.next() else { return false }
                group.addTask { try await sendPart(of: ipa, operation: operation, fileID: fileID) }
                running += 1
                return true
            }

            while running < configuration.maxConcurrentParts, startNext() {}
            while running > 0 {
                try await group.next()
                running -= 1
                completed += 1
                onEvent(.uploadedPart(completed: completed, total: operations.count))
                _ = startNext()
            }
        }
    }

    private func sendPart(
        of ipa: URL,
        operation: Components.Schemas.DeliveryFileUploadOperation,
        fileID: String
    ) async throws {
        guard let offset = operation.offset, let length = operation.length, offset >= 0, length >= 0
        else { throw Error.malformedResponse("an upload operation is incomplete") }

        let data = try readPart(of: ipa, offset: offset, length: length)

        do {
            var operation = operation
            try await retrying(isRetryable: Self.isRetryablePut) {
                // pre-signed URLs stop working at some point. The reservation can be read again to get new ones.
                // refresh a bit early: our clock and the storage backend's may disagree
                if let expiration = operation.expiration, expiration <= date.now.addingTimeInterval(Self.urlRefreshMargin) {
                    operation = try await refreshed(operation, fileID: fileID)
                }
                guard let url = operation.url.flatMap({ URL(string: $0) }) else {
                    throw Error.malformedResponse("an upload operation has an invalid URL")
                }
                var request = HTTPRequest(
                    method: operation.method.flatMap { HTTPRequest.Method($0) } ?? .put,
                    url: url
                )
                for header in operation.requestHeaders ?? [] {
                    if let name = header.name.flatMap({ HTTPField.Name($0) }), let value = header.value {
                        request.headerFields[name] = value
                    }
                }
                // The URL is pre-signed: sending our App Store Connect credentials to it would leak
                // them to a third party (Apple's storage backend), so this goes through the bare client
                // instead of `client`, and no `Authorization` header is ever added.
                _ = try await httpClient.makeRequest(request, body: data)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Error.partUploadFailed(partNumber: operation.partNumber, underlying: error)
        }
    }

    private func refreshed(
        _ operation: Components.Schemas.DeliveryFileUploadOperation,
        fileID: String
    ) async throws -> Components.Schemas.DeliveryFileUploadOperation {
        let file = try await retrying {
            try await client.buildUploadFilesGetInstance(path: .init(id: fileID)).ok.body.json.data
        }
        let candidates = file.attributes?.uploadOperations ?? []
        guard let match = candidates.first(where: { $0.offset == operation.offset && $0.length == operation.length })
        else { throw Error.malformedResponse("the reservation no longer has part \(operation.partNumber ?? 0)") }
        return match
    }

    private func readPart(of ipa: URL, offset: Int64, length: Int64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: ipa)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: Int(length)), data.count == Int(length) else {
            throw Error.unreadablePart(offset: offset, length: length)
        }
        return data
    }

    private func commit(fileID: String) async throws {
        let body = Components.Schemas.BuildUploadFileUpdateRequest(data: .init(
            _type: .buildUploadFiles,
            id: fileID,
            attributes: .init(uploaded: true)
        ))
        func patch() async throws {
            _ = try await call {
                try await client.buildUploadFilesUpdateInstance(path: .init(id: fileID), body: .json(body)).ok
            }
        }
        do {
            try await patch()
        } catch where Self.isAmbiguous(error) {
            // The request may or may not have been applied. Don't guess: ask.
            let state = try await fileState(fileID)
            switch state {
            case "UPLOAD_COMPLETE", "COMPLETE":
                return
            case "AWAITING_UPLOAD":
                // not applied. Committing twice is harmless so try once more.
                try await patch()
            default:
                throw error
            }
        }
    }

    private func fileState(_ fileID: String) async throws -> String? {
        try await retrying {
            try await client.buildUploadFilesGetInstance(path: .init(id: fileID))
                .ok.body.json.data.attributes?.assetDeliveryState?.state?.string
        }
    }

    // MARK: - Processing

    private func status(of uploadID: String) async throws -> Result {
        let upload = try await retrying {
            try await client.buildUploadsGetInstance(path: .init(id: uploadID)).ok.body.json.data
        }
        let state = upload.attributes?.state
        return Result(
            uploadID: uploadID,
            state: state?.state?.string ?? "UNKNOWN",
            warnings: (state?.warnings ?? []).map(\.summary),
            infos: (state?.infos ?? []).map(\.summary)
        )
    }

    private func waitForProcessing(uploadID: String, onEvent: (Event) -> Void) async throws -> Result {
        var interval = configuration.pollInterval
        var elapsed = Duration.zero
        while true {
            let upload = try await retrying {
                try await client.buildUploadsGetInstance(path: .init(id: uploadID)).ok.body.json.data
            }
            let state = upload.attributes?.state
            let name = state?.state?.string ?? "UNKNOWN"
            onEvent(.processing(state: name))

            switch name {
            case "COMPLETE":
                return Result(
                    uploadID: uploadID,
                    state: name,
                    warnings: (state?.warnings ?? []).map(\.summary),
                    infos: (state?.infos ?? []).map(\.summary)
                )
            case "FAILED":
                let errors = (state?.errors ?? []).map(\.summary)
                throw Error.processingFailed(
                    uploadID: uploadID,
                    errors: errors.isEmpty ? ["no details were provided"] : errors
                )
            default:
                break
            }

            guard elapsed < configuration.timeout else { throw Error.timedOut(uploadID: uploadID) }
            try await clock.sleep(for: interval)
            elapsed += interval
            interval = min(interval * 1.5, configuration.maxPollInterval)
        }
    }

    // MARK: - Retries

    /// Runs a request to App Store Connect.
    ///
    /// OpenAPIRuntime wraps whatever a middleware throws in a `ClientError`. This puts our own errors back.
    private func call<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as ClientError {
            throw error.underlyingError
        }
    }

    /// Retries `operation` with an exponential backoff. Only use this for requests that can safely be
    /// repeated: reads, and writes to pre-signed URLs.
    private func retrying<T>(
        isRetryable: (Swift.Error) -> Bool = BuildUploader.isRetryableRead,
        _ operation: () async throws -> T
    ) async throws -> T {
        var delay = configuration.retryDelay
        var attempt = 1
        while true {
            do {
                return try await call(operation)
            } catch {
                guard attempt < configuration.maxAttempts, isRetryable(error) else { throw error }
                try await clock.sleep(for: delay)
                delay *= 2
                attempt += 1
            }
        }
    }

    private static func isRetryableRead(_ error: Swift.Error) -> Bool {
        if error is CancellationError { return false }
        if case Error.http(let status, _) = error {
            // App Store Connect sometimes answers 404 "There is no resource of type 'apps'" for an app
            // that exists, and reads right after a write can lag behind it.
            return status == 404 || isTransient(status: status)
        }
        // errors from the transport
        return !(error is Error)
    }

    private static func isRetryablePut(_ error: Swift.Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? HTTPResponseError { return isTransient(status: error.status.code) }
        return !(error is Error)
    }

    /// Whether the write may have been applied even though we got an error.
    private static func isAmbiguous(_ error: Swift.Error) -> Bool {
        if error is CancellationError { return false }
        if case Error.http(let status, _) = error { return status >= 500 || status == 408 }
        return !(error is Error)
    }

    private static func isTransient(status: Int) -> Bool {
        status == 408 || status == 429 || status >= 500
    }
}

// MARK: - Helpers

extension Components.Schemas.StateDetail {
    fileprivate var summary: String {
        switch (code, description) {
        case let (code?, description?): "\(code): \(description)"
        case let (code?, nil): code
        case let (nil, description?): description
        case (nil, nil): "unknown"
        }
    }
}

extension OpenAPIExtensibleEnum {
    fileprivate var string: String? { value1?.rawValue ?? value2 }
}

/// Turns non-2xx responses into ``BuildUploader/Error/http(status:details:)``, with Apple's own explanation.
private struct HTTPStatusMiddleware: ClientMiddleware {
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        guard response.status.kind != .successful else { return (response, responseBody) }

        var details = ""
        if let responseBody, let data = try? await Data(collecting: responseBody, upTo: 1 << 20) {
            details = Self.details(of: data)
        }
        throw BuildUploader.Error.http(status: response.status.code, details: details)
    }

    /// `{"errors": [{"title": ..., "detail": ...}]}`
    private static func details(of data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = object["errors"] as? [[String: Any]]
        else { return String(decoding: data.prefix(500), as: UTF8.self) }
        return errors
            .compactMap { error in
                [error["code"], error["title"], error["detail"]]
                    .compactMap { $0 as? String }
                    .joined(separator: " - ")
            }
            .joined(separator: "; ")
    }
}

/// Apple writes some dates with fractional seconds and others without.
private struct LenientISO8601DateTranscoder: DateTranscoder {
    func encode(_ date: Date) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func decode(_ dateString: String) throws -> Date {
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: dateString) { return date }
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "Expected an ISO 8601 date, got \(dateString)")
        )
    }
}
