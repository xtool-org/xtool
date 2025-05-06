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

public typealias HTTPRequest = HTTPTypes.HTTPRequest
public typealias HTTPResponse = HTTPTypes.HTTPResponse
public typealias HTTPBody = OpenAPIRuntime.HTTPBody

public protocol HTTPClientProtocol: Sendable {
    var asOpenAPITransport: ClientTransport { get }

    func makeWebSocket(url: URL) async throws -> WebSocketSession
}

extension HTTPClientProtocol {
    public func send(
        _ request: HTTPRequest,
        body: HTTPBody? = nil
    ) async throws -> (response: HTTPResponse, body: HTTPBody?) {
        let transport = asOpenAPITransport
        let request = request
        var baseComponents = URLComponents()
        baseComponents.scheme = request.scheme
        baseComponents.host = request.authority
        return try await transport.send(
            request,
            body: body,
            baseURL: baseComponents.url!,
            operationID: "dummy"
        )
    }

    public func makeRequest(
        _ request: HTTPRequest,
        body: Data? = nil,
        onProgress: @isolated(any) (Double?) -> Void = { _ in }
    ) async throws -> (response: HTTPResponse, body: Data) {
        await onProgress(0)
        let (response, body) = try await send(request, body: body.map { HTTPBody($0) })
        guard let body else {
            return (response, Data())
        }
        switch body.length {
        case .unknown:
            return (response, try await body.reduce(into: Data()) { $0 += $1 })
        case .known(let length):
            var data = Data(capacity: Int(length))
            let total = Double(length)
            for try await chunk in body {
                data += chunk
                await onProgress(min(Double(data.count) / total, 1))
            }
            return (response, data)
        }
    }
}

private struct UnimplementedHTTPClient: HTTPClientProtocol, ClientTransport {
    public var asOpenAPITransport: ClientTransport { self }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let closure: (HTTPRequest, HTTPBody?, URL, String) async throws -> (HTTPResponse, HTTPBody?) = unimplemented()
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
