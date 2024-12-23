//
//  HTTPClientProtocol.swift
//
//
//  Created by Kabir Oberai on 05/05/21.
//

import Foundation
import OpenAPIRuntime
import Dependencies
import HTTPTypes

public struct HTTPRequest: Sendable {
    public enum Body: Sendable {
        case buffer(Data)
    }

    public var url: URL
    public var method: String?
    public var headers: [String: String]
    public var body: Body?

    public init(
        url: URL,
        method: String? = nil,
        headers: [String: String] = [:],
        body: Body? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var url: URL
    public var status: Int
    public var headers: [String: String]
    public var body: Data?

    public init(
        url: URL,
        status: Int,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.url = url
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public protocol HTTPClientProtocol: Sendable {
    var asOpenAPITransport: ClientTransport { get }

    func makeRequest(
        _ request: HTTPRequest,
        onProgress: sending @isolated(any) (Double?) -> Void
    ) async throws -> HTTPResponse

    func makeWebSocket(url: URL) async throws -> WebSocketSession
}

extension HTTPClientProtocol {
    public func makeRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await makeRequest(request) { _ in }
    }
}

private struct UnimplementedHTTPClient: HTTPClientProtocol, ClientTransport {
    public var asOpenAPITransport: ClientTransport { self }

    func send(
        _ request: HTTPTypes.HTTPRequest,
        body: OpenAPIRuntime.HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?) {
        let closure: (HTTPTypes.HTTPRequest, OpenAPIRuntime.HTTPBody?, URL, String) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?) = unimplemented()
        return try await closure(request, body, baseURL, operationID)
    }

    func makeRequest(
        _ request: HTTPRequest,
        onProgress: sending @isolated(any) (Double?) -> Void
    ) async throws -> HTTPResponse {
        let closure: () throws -> HTTPResponse = unimplemented()
        return try closure()
    }

    public func makeWebSocket(url: URL) async throws -> any WebSocketSession {
        let closure: (URL) async throws -> any WebSocketSession = unimplemented()
        return try await closure(url)
    }
}

public enum HTTPClientDependencyKey: TestDependencyKey {
    public static let testValue: HTTPClientProtocol = UnimplementedHTTPClient()
}

extension DependencyValues {
    public var httpClient: HTTPClientProtocol {
        get { self[HTTPClientDependencyKey.self] }
        set { self[HTTPClientDependencyKey.self] = newValue }
    }
}

public protocol WebSocketSession: Sendable {
    func receive() async throws -> WebSocketMessage
    func send(_ message: WebSocketMessage) async throws
    func close()
}

public enum WebSocketMessage: Sendable {
    case text(String)
    case data(Data)
}
