//
//  HTTPClientProtocol.swift
//
//
//  Created by Kabir Oberai on 05/05/21.
//

import Foundation
import OpenAPIRuntime

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

public protocol WebSocketSession: Sendable {
    func receive() async throws -> WebSocketMessage
    func send(_ message: WebSocketMessage) async throws
    func close()
}

public enum WebSocketMessage: Sendable {
    case text(String)
    case data(Data)
}

public protocol HTTPClientFactory: Sendable {
    func shutdown() // client is invalidated after this
    func makeClient() -> HTTPClientProtocol
}

public let defaultHTTPClientFactory: HTTPClientFactory = {
    #if os(Linux)
    return AsyncHTTPClientFactory.shared
    #else
    return URLHTTPClientFactory.shared
    #endif
}()
