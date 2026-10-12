import Foundation
import Testing
import ConcurrencyExtras
import Crypto
import Dependencies
import HTTPTypes
@testable import XKit

private let links = #""links": {"self": "https://api.appstoreconnect.apple.com/v1/x"}"#

private func uploadJSON(
    state: String,
    errors: [(code: String, description: String)] = [],
    warnings: [(code: String, description: String)] = []
) -> String {
    func details(_ values: [(code: String, description: String)]) -> String {
        values.map { #"{"code": "\#($0.code)", "description": "\#($0.description)"}"# }.joined(separator: ",")
    }
    return """
    {"data": {"type": "buildUploads", "id": "U1", "attributes": {
      "cfBundleShortVersionString": "1.2.3", "cfBundleVersion": "45", "platform": "IOS",
      "createdDate": "2026-10-11T10:00:00-07:00",
      "state": {"state": "\(state)", "errors": [\(details(errors))], "warnings": [\(details(warnings))], "infos": []}
    }}, \(links)}
    """
}

private func fileJSON(state: String = "AWAITING_UPLOAD", operations: [String] = []) -> String {
    """
    {"data": {"type": "buildUploadFiles", "id": "F1", "attributes": {
      "fileName": "App.ipa", "fileSize": 7,
      "assetDeliveryState": {"state": "\(state)"},
      "uploadOperations": [\(operations.joined(separator: ","))]
    }}, \(links)}
    """
}

private func operation(part: Int, offset: Int, length: Int, expiration: String = "2099-01-01T00:00:00.000Z") -> String {
    """
    {"method": "PUT", "url": "https://uploads.example.com/part\(part)?signature=abc", "offset": \(offset),
     "length": \(length), "partNumber": \(part), "expiration": "\(expiration)",
     "requestHeaders": [{"name": "Content-Type", "value": "application/octet-stream"}]}
    """
}

private let twoParts = fileJSON(operations: [
    operation(part: 1, offset: 0, length: 4),
    operation(part: 2, offset: 4, length: 3),
])

private let info = IPAInfo(bundleID: "com.example.App", version: "1.2.3", build: "45", platform: "IOS")

private func makeIPA() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("BuildUploaderTests-\(UUID().uuidString).ipa")
    try Data("abcdefg".utf8).write(to: url)
    return url
}

private func makeKey() -> ASCKey {
    ASCKey(id: "KEYID", issuerID: "ISSUER", pem: P256.Signing.PrivateKey().pemRepresentation)
}

/// Run `operation` against `client`, without ever sleeping for real.
private func withMock<T>(
    _ client: MockHTTPClient,
    _ operation: () async throws -> T
) async throws -> T {
    try await withDependencies {
        $0.httpClient = client
        $0.continuousClock = ImmediateClock()
    } operation: {
        try await operation()
    }
}

/// The routes of a build upload that goes well. `override` can answer first, to inject failures.
private func happyPath(
    processing: @escaping @Sendable () -> String = { uploadJSON(state: "COMPLETE") },
    override: @escaping @Sendable (MockHTTPClient.Request) -> MockHTTPClient.Response? = { _ in nil }
) -> MockHTTPClient {
    MockHTTPClient { request in
        if let response = override(request) { return response }
        switch (request.method, request.path.split(separator: "?").first.map(String.init) ?? "") {
        case (.post, "/v1/buildUploads"):
            return .init(201, uploadJSON(state: "AWAITING_UPLOAD"))
        case (.post, "/v1/buildUploadFiles"):
            return .init(201, twoParts)
        case (.put, _):
            return .init(200)
        case (.patch, "/v1/buildUploadFiles/F1"):
            return .init(200, fileJSON(state: "UPLOAD_COMPLETE"))
        case (.get, "/v1/buildUploads/U1"):
            return .init(200, processing())
        case (.delete, "/v1/buildUploads/U1"):
            return .init(204)
        default:
            return .init(404, #"{"errors": [{"title": "unexpected \#(request.method) \#(request.path)"}]}"#)
        }
    }
}

@Suite struct BuildUploaderTests {
    @Test func uploadsAllPartsAndWaitsForProcessing() async throws {
        let ipa = try makeIPA()
        defer { try? FileManager.default.removeItem(at: ipa) }

        let polls = LockIsolated(0)
        let client = happyPath(processing: {
            let count = polls.withValue { $0 += 1; return $0 }
            return count < 3
                ? uploadJSON(state: "PROCESSING")
                : uploadJSON(state: "COMPLETE", warnings: [("90001", "Missing push entitlement")])
        })

        let events = LockIsolated<[BuildUploader.Event]>([])
        let result = try await withMock(client) {
            try await BuildUploader(key: makeKey()).upload(ipa: ipa, info: info, appID: "APP1", wait: true) { event in
                events.withValue { $0.append(event) }
            }
        }

        #expect(result.state == "COMPLETE")
        #expect(result.uploadID == "U1")
        #expect(result.warnings == ["90001: Missing push entitlement"])
        #expect(polls.value == 3)

        // the build upload is created for the right app and version
        let create = try #require(client.recorded(.post, "/v1/buildUploads").first?.bodyJSON)
        let data = try #require(create["data"] as? [String: Any])
        let attributes = try #require(data["attributes"] as? [String: Any])
        #expect(attributes["cfBundleShortVersionString"] as? String == "1.2.3")
        #expect(attributes["cfBundleVersion"] as? String == "45")
        #expect(attributes["platform"] as? String == "IOS")
        #expect(create.description.contains("APP1"))

        // the file is reserved with its real size
        let reservation = try #require(client.recorded(.post, "/v1/buildUploadFiles").first?.bodyJSON)
        let reservedAttributes = try #require((reservation["data"] as? [String: Any])?["attributes"] as? [String: Any])
        #expect(reservedAttributes["fileSize"] as? Int == 7)
        #expect(reservedAttributes["uti"] as? String == "com.apple.ipa")
        #expect(reservedAttributes["assetType"] as? String == "ASSET")

        // each part is the right slice of the file, sent with Apple's headers
        let puts = client.recorded(.put, "/part")
        #expect(Set(puts.map(\.bodyString)) == ["abcd", "efg"])
        #expect(puts.allSatisfy { $0.host == "uploads.example.com" })
        #expect(puts.allSatisfy { $0.headers[.contentType] == "application/octet-stream" })
        // pre-signed URLs must never see our credentials
        #expect(puts.allSatisfy { $0.headers[.authorization] == nil })
        let apiCalls = client.requests.value.filter { $0.host == "api.appstoreconnect.apple.com" }
        #expect(!apiCalls.isEmpty)
        #expect(apiCalls.allSatisfy { $0.headers[.authorization]?.hasPrefix("Bearer ") == true })

        // then the file is committed, after all parts
        let commit = try #require(client.recorded(.patch, "/v1/buildUploadFiles/F1").first)
        let committed = try #require((commit.bodyJSON?["data"] as? [String: Any])?["attributes"] as? [String: Any])
        #expect(committed["uploaded"] as? Bool == true)
        let order = client.requests.value.map { "\($0.method.rawValue)" }
        #expect(order.lastIndex(of: "PUT")! < order.firstIndex(of: "PATCH")!)

        #expect(events.value.first == .createdUpload(id: "U1"))
        #expect(events.value.contains(.reservedFile(parts: 2)))
        #expect(events.value.contains(.uploadedPart(completed: 2, total: 2)))
        #expect(events.value.contains(.committedFile))
        #expect(events.value.last == .processing(state: "COMPLETE"))
    }

    @Test func doesNotWaitUnlessAsked() async throws {
        let ipa = try makeIPA()
        defer { try? FileManager.default.removeItem(at: ipa) }

        let client = happyPath(processing: { uploadJSON(state: "PROCESSING") })
        let result = try await withMock(client) {
            try await BuildUploader(key: makeKey()).upload(ipa: ipa, info: info, appID: "APP1", wait: false)
        }
        #expect(result.state == "PROCESSING")
        #expect(client.recorded(.get, "/v1/buildUploads/U1").count == 1)
    }

    @Test func surfacesTheErrorsApplePutsInAFailedBuild() async throws {
        let ipa = try makeIPA()
        defer { try? FileManager.default.removeItem(at: ipa) }

        let client = happyPath(processing: {
            uploadJSON(state: "FAILED", errors: [
                ("STATE_ERROR.VALIDATION_ERROR.90713", "Missing Info.plist value: CFBundleIconName"),
                ("STATE_ERROR.VALIDATION_ERROR.90534", "Invalid SDK"),
            ])
        })

        let error = await #expect(throws: BuildUploader.Error.self) {
            try await withMock(client) {
                try await BuildUploader(key: makeKey()).upload(ipa: ipa, info: info, appID: "APP1", wait: true)
            }
        }
        guard case .processingFailed(let uploadID, let errors) = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(uploadID == "U1")
        #expect(errors == [
            "STATE_ERROR.VALIDATION_ERROR.90713: Missing Info.plist value: CFBundleIconName",
            "STATE_ERROR.VALIDATION_ERROR.90534: Invalid SDK",
        ])
        #expect(error?.description.contains("CFBundleIconName") == true)
    }

    @Test func givesUpWhenProcessingNeverEnds() async throws {
        let ipa = try makeIPA()
        defer { try? FileManager.default.removeItem(at: ipa) }

        let client = happyPath(processing: { uploadJSON(state: "PROCESSING") })
        let error = await #expect(throws: BuildUploader.Error.self) {
            try await withMock(client) {
                try await BuildUploader(key: makeKey()).upload(ipa: ipa, info: info, appID: "APP1", wait: true)
            }
        }
        guard case .timedOut(let uploadID) = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(uploadID == "U1")
    }

    @Test func retriesAPartThatFailsTemporarily() async throws {
        let ipa = try makeIPA()
        defer { try? FileManager.default.removeItem(at: ipa) }

        let attempts = LockIsolated(0)
        let client = happyPath(override: { request in
            guard request.method == .put, request.path.hasPrefix("/part1") else { return nil }
            return attempts.withValue { $0 += 1; return $0 } < 3 ? .init(503, "try later") : nil
        })

        let result = try await withMock(client) {
            try await BuildUploader(key: makeKey()).upload(ipa: ipa, info: info, appID: "APP1", wait: true)
        }
        #expect(result.state == "COMPLETE")
        #expect(client.recorded(.put, "/part1").count == 3)
        // the other part was not affected
        #expect(client.recorded(.put, "/part2").count == 1)
    }

    @Test func abandonsTheUploadWhenAPartKeepsFailing() async throws {
        let ipa = try makeIPA()
        defer { try? FileManager.default.removeItem(at: ipa) }

        let client = happyPath(override: { request in
            request.method == .put && request.path.hasPrefix("/part2") ? .init(500, "boom") : nil
        })

        let error = await #expect(throws: BuildUploader.Error.self) {
            try await withMock(client) {
                try await BuildUploader(key: makeKey()).upload(ipa: ipa, info: info, appID: "APP1", wait: true)
            }
        }
        guard case .partUploadFailed(let part, _) = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(part == 2)
        // bounded: 4 attempts, not forever
        #expect(client.recorded(.put, "/part2").count == 4)
        // nothing was committed, and the reservation is cleaned up
        #expect(client.recorded(.patch, "/v1").isEmpty)
        #expect(client.recorded(.delete, "/v1/buildUploads/U1").count == 1)
    }

    @Test func doesNotRetryWritesToAppStoreConnect() async throws {
        let ipa = try makeIPA()
        defer { try? FileManager.default.removeItem(at: ipa) }

        let client = happyPath(override: { request in
            request.method == .post && request.path == "/v1/buildUploads"
                ? .init(409, #"{"errors": [{"code": "ENTITY_ERROR", "title": "Duplicate build", "detail": "Build 45 exists"}]}"#)
                : nil
        })

        let error = await #expect(throws: BuildUploader.Error.self) {
            try await withMock(client) {
                try await BuildUploader(key: makeKey()).upload(ipa: ipa, info: info, appID: "APP1", wait: true)
            }
        }
        guard case .http(let status, let details) = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(status == 409)
        #expect(details.contains("Build 45 exists"))
        #expect(client.recorded(.post, "/v1/buildUploads").count == 1)
        #expect(client.recorded(.put, "/part").isEmpty)
    }

    @Test func checksTheStateWhenTheCommitIsAmbiguous() async throws {
        let ipa = try makeIPA()
        defer { try? FileManager.default.removeItem(at: ipa) }

        // the PATCH reached Apple, but the answer was lost
        let client = happyPath(override: { request in
            request.method == .patch ? .init(502, "bad gateway") : nil
        })
        let reads = LockIsolated(0)
        let tracking = MockHTTPClient { request in
            if request.method == .get, request.path == "/v1/buildUploadFiles/F1" {
                reads.withValue { $0 += 1 }
                return .init(200, fileJSON(state: "UPLOAD_COMPLETE"))
            }
            return try await client.handler(request)
        }

        let result = try await withMock(tracking) {
            try await BuildUploader(key: makeKey()).upload(ipa: ipa, info: info, appID: "APP1", wait: true)
        }
        #expect(result.state == "COMPLETE")
        #expect(reads.value == 1)
        // it was not committed a second time
        #expect(tracking.recorded(.patch, "/v1/buildUploadFiles/F1").count == 1)
        // and the upload was not thrown away
        #expect(tracking.recorded(.delete, "/v1").isEmpty)
    }

    @Test func commitsAgainWhenTheFirstCommitDidNotLand() async throws {
        let ipa = try makeIPA()
        defer { try? FileManager.default.removeItem(at: ipa) }

        let patches = LockIsolated(0)
        let client = MockHTTPClient { request in
            if request.method == .patch {
                return patches.withValue { $0 += 1; return $0 } == 1 ? .init(503) : .init(200, fileJSON(state: "UPLOAD_COMPLETE"))
            }
            if request.method == .get, request.path == "/v1/buildUploadFiles/F1" {
                return .init(200, fileJSON(state: "AWAITING_UPLOAD"))
            }
            return try await happyPath().handler(request)
        }

        let result = try await withMock(client) {
            try await BuildUploader(key: makeKey()).upload(ipa: ipa, info: info, appID: "APP1", wait: true)
        }
        #expect(result.state == "COMPLETE")
        #expect(patches.value == 2)
    }

    @Test func getsFreshURLsWhenAPartExpired() async throws {
        let ipa = try makeIPA()
        defer { try? FileManager.default.removeItem(at: ipa) }

        let expired = fileJSON(operations: [
            operation(part: 1, offset: 0, length: 4, expiration: "2001-01-01T00:00:00Z"),
            operation(part: 2, offset: 4, length: 3),
        ])
        let client = MockHTTPClient { request in
            switch (request.method, request.path) {
            case (.post, "/v1/buildUploadFiles"):
                return .init(201, expired)
            case (.get, "/v1/buildUploadFiles/F1"):
                return .init(200, twoParts)
            default:
                return try await happyPath().handler(request)
            }
        }

        let result = try await withMock(client) {
            try await BuildUploader(key: makeKey()).upload(ipa: ipa, info: info, appID: "APP1", wait: true)
        }
        #expect(result.state == "COMPLETE")
        #expect(client.recorded(.get, "/v1/buildUploadFiles/F1").count == 1)
        #expect(client.recorded(.put, "/part1").count == 1)
    }

    @Test func resolvesTheAppFromTheBundleID() async throws {
        let attempts = LockIsolated(0)
        let client = MockHTTPClient { request in
            switch request.path.split(separator: "?").first.map(String.init) ?? "" {
            case "/v1/bundleIds":
                // the identifier filter is not an exact match
                return .init(200, """
                {"data": [
                  {"type": "bundleIds", "id": "B0", "attributes": {"identifier": "com.example.App.extension"}},
                  {"type": "bundleIds", "id": "B1", "attributes": {"identifier": "com.example.App"}}
                ], \(links)}
                """)
            case "/v1/bundleIds/B1/app":
                // App Store Connect sometimes answers 404 for an app that does exist
                return attempts.withValue { $0 += 1; return $0 } == 1
                    ? .init(404, #"{"errors": [{"title": "There is no resource of type 'apps'"}]}"#)
                    : .init(200, #"{"data": {"type": "apps", "id": "APP1"}, \#(links)}"#)
            default:
                return .init(500)
            }
        }

        let appID = try await withMock(client) {
            try await BuildUploader(key: makeKey()).resolveApp(bundleID: "com.example.App")
        }
        #expect(appID == "APP1")
        #expect(attempts.value == 2)
    }

    @Test func reportsAnUnknownApp() async throws {
        let client = MockHTTPClient { _ in .init(200, #"{"data": [], \#(links)}"#) }

        let error = await #expect(throws: BuildUploader.Error.self) {
            try await withMock(client) {
                try await BuildUploader(key: makeKey()).resolveApp(bundleID: "com.example.Missing")
            }
        }
        guard case .appNotFound(let bundleID) = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(bundleID == "com.example.Missing")
    }

    @Test func doesNotRetryReadsThatCannotSucceed() async throws {
        let client = MockHTTPClient { _ in
            .init(401, #"{"errors": [{"code": "NOT_AUTHORIZED", "title": "Authentication credentials are missing or invalid."}]}"#)
        }

        let error = await #expect(throws: BuildUploader.Error.self) {
            try await withMock(client) {
                try await BuildUploader(key: makeKey()).resolveApp(bundleID: "com.example.App")
            }
        }
        guard case .http(let status, let details) = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(status == 401)
        #expect(details.contains("NOT_AUTHORIZED"))
        #expect(client.requests.value.count == 1)
    }
}
