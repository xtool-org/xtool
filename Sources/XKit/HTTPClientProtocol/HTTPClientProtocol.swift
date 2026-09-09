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

    func withEphemeralClient<T>(
        perform: (any HTTPClientProtocol) async throws -> T
    ) async throws -> T
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
        throwOnServerError: Bool = true,
        onProgress: @isolated(any) (Double?) -> Void = { _ in }
    ) async throws -> (response: HTTPResponse, body: Data) {
        await onProgress(0)
        let (response, responseBody) = try await send(request, body: body.map { HTTPBody($0) })
        guard !throwOnServerError || response.status.kind != .serverError else {
            let errorBody = (try? await responseBody.collect()) ?? Data()
            throw HTTPResponseError(
                method: request.method,
                url: "\(request.scheme ?? "https")://\(request.authority ?? "")\(request.path ?? "")",
                status: response.status,
                // we don't use `decoding:as:` because we want to validate the UTF8
                body: String(data: errorBody, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return (response, try await responseBody.collect(onProgress: onProgress))
    }
}

extension HTTPBody? {
    fileprivate func collect(
        onProgress: @isolated(any) (Double?) -> Void = { _ in }
    ) async throws -> Data {
        try await self?.collect(onProgress: onProgress) ?? Data()
    }
}

extension HTTPBody {
    fileprivate func collect(
        onProgress: @isolated(any) (Double?) -> Void
    ) async throws -> Data {
        switch self.length {
        case .unknown:
            return try await self.reduce(into: Data()) { $0 += $1 }
        case .known(let length):
            var data = Data(capacity: Int(length))
            let total = Double(length)
            for try await chunk in self {
                data += chunk
                await onProgress(Swift.min(Double(data.count) / total, 1))
            }
            return data
        }
    }
}

public struct HTTPResponseError: Error, LocalizedError, Sendable, CustomStringConvertible {
    public let method: HTTPRequest.Method
    public let url: String
    public let status: HTTPResponse.Status
    public let body: String?

    public var description: String {
        var description = "\(method.rawValue) \(url) failed: HTTP \(status.code)"
        if !status.reasonPhrase.isEmpty {
            description += " \(status.reasonPhrase)"
        }
        if let body, !body.isEmpty {
            description += ". Details:\n\(body)"
        }
        return description
    }

    public var errorDescription: String? { description }
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

    func withEphemeralClient<T>(
        perform: (any HTTPClientProtocol) async throws -> T
    ) async throws -> T {
        try await perform(self)
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
