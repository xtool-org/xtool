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

public final class HTTPTask {
    private var cancellationHandler: () -> Void
    public init(cancellationHandler: @escaping () -> Void) {
        self.cancellationHandler = cancellationHandler
    }
    public func cancel() {
        cancellationHandler()
    }
}

public protocol HTTPClientProtocol {
    @discardableResult
    func makeRequest(_ request: HTTPRequest, completion: @escaping (Result<HTTPResponse, Error>) -> Void) -> HTTPTask
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
