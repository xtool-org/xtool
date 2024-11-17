//
//  HTTPClientProtocol.swift
//
//
//  Created by Kabir Oberai on 05/05/21.
//

import Foundation

public struct HTTPRequest {
    public enum Body {
        case buffer(Data)
//        case stream(InputStream)
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

public struct HTTPResponse {
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

public protocol HTTPClientProtocol {
    func makeRequest(_ request: HTTPRequest) async throws -> HTTPResponse
    func makeWebSocket(url: URL) async throws -> WebSocketSession
}

public protocol WebSocketSession {
    func receive() async throws -> WebSocketMessage
    func send(_ message: WebSocketMessage) async throws
    func close()
}

public enum WebSocketMessage {
    case text(String)
    case data(Data)
}

public protocol HTTPClientFactory {
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
