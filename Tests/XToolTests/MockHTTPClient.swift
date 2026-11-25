import Foundation
import ConcurrencyExtras
import HTTPTypes
import OpenAPIRuntime
@testable import XKit

/// An `HTTPClientProtocol` that answers from a closure and records what it was asked.
struct MockHTTPClient: HTTPClientProtocol, ClientTransport {
    struct Request: Sendable {
        var method: HTTPRequest.Method
        var host: String
        var path: String
        var headers: HTTPFields
        var body: Data

        var bodyString: String { String(decoding: body, as: UTF8.self) }
        var bodyJSON: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
    }

    struct Response: Sendable {
        var status: Int
        var body: String

        init(_ status: Int = 200, _ body: String = "") {
            self.status = status
            self.body = body
        }
    }

    let requests = LockIsolated<[Request]>([])
    let handler: @Sendable (Request) async throws -> Response

    init(handler: @escaping @Sendable (Request) async throws -> Response) {
        self.handler = handler
    }

    func recorded(_ method: HTTPRequest.Method, _ pathPrefix: String) -> [Request] {
        requests.value.filter { $0.method == method && $0.path.hasPrefix(pathPrefix) }
    }

    var asOpenAPITransport: ClientTransport { self }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var data = Data()
        if let body {
            data = try await Data(collecting: body, upTo: .max)
        }
        let recorded = Request(
            method: request.method,
            host: baseURL.host ?? "",
            path: request.path ?? "",
            headers: request.headerFields,
            body: data
        )
        requests.withValue { $0.append(recorded) }

        let response = try await handler(recorded)
        var fields = HTTPFields()
        fields[.contentType] = "application/json"
        return (
            HTTPResponse(status: .init(code: response.status), headerFields: fields),
            response.body.isEmpty ? nil : HTTPBody(response.body)
        )
    }

    func makeWebSocket(url: URL) async throws -> WebSocketSession {
        throw CancellationError()
    }

    func withEphemeralClient<T>(
        perform: (any HTTPClientProtocol) async throws -> T
    ) async throws -> T {
        try await perform(self)
    }
}
