//
//  URLSession+HTTPClientProtocol.swift
//
//
//  Created by Kabir Oberai on 05/05/21.
//

#if !os(Linux)
import Foundation

public struct UnknownHTTPError: Error {}

final class URLHTTPClientFactory: HTTPClientFactory {
    static let shared = URLHTTPClientFactory()

    private let client = Client()

    func shutdown() {}
    func makeClient() -> HTTPClientProtocol { client }
}

private final class Client: HTTPClientProtocol {
    final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
        var callbacks: [URLSessionWebSocketTask: (URLSessionWebSocketTask.CloseCode?) -> Void] = [:]

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didOpenWithProtocol protocol: String?
        ) {
            callbacks.removeValue(forKey: webSocketTask)?(nil)
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
            reason: Data?
        ) {
            callbacks.removeValue(forKey: webSocketTask)?(closeCode)
        }
    }

    private let webSocketDelegate = WebSocketDelegate()
    private let session: URLSession

    init() {
        // no need for cert handling since the Apple Root CA is already
        // installed on any devices which support the Security APIs which
        // would have been required to add the custom root anyway
        self.session = URLSession(configuration: .ephemeral, delegate: webSocketDelegate, delegateQueue: .main)
    }

    public func makeRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        var req = URLRequest(url: request.url)
        req.httpMethod = request.method
        request.headers.forEach { k, v in
            req.setValue(v, forHTTPHeaderField: k)
        }
        switch request.body {
        case .buffer(let data):
            req.httpBody = data
//        case .stream(let stream):
//            req.httpBodyStream = stream
        case nil:
            break
        }
        let (data, resp) = try await session.data(for: req)
        guard let httpResp = resp as? HTTPURLResponse else { throw UnknownHTTPError() }
        let headers = [String: String](
            uniqueKeysWithValues: httpResp.allHeaderFields.compactMap { k, v in
                guard let kStr = k as? String,
                      let vStr = v as? String
                else { return nil }
                return (kStr, vStr)
            }
        )
        return HTTPResponse(
            url: request.url,
            status: httpResp.statusCode,
            headers: headers,
            body: data
        )
    }

    public func makeWebSocket(url: URL) async throws -> any WebSocketSession {
        let task = session.webSocketTask(with: url)
        async let event = withCheckedContinuation { continuation in
            webSocketDelegate.callbacks[task] = { continuation.resume(returning: $0) }
        }
        task.resume()
        let code = await event
        if let code { throw Errors.webSocketClosed(code) }
        return WebSocketSessionWrapper(task: task)
    }

    enum Errors: Error {
        case webSocketClosed(URLSessionWebSocketTask.CloseCode)
    }
}

private final class WebSocketSessionWrapper: WebSocketSession {
    let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func receive() async throws -> WebSocketMessage {
        switch try await task.receive() {
        case .data(let data): .data(data)
        case .string(let text): .text(text)
        @unknown default: .data(Data())
        }
    }

    func send(_ message: WebSocketMessage) async throws {
        let message: URLSessionWebSocketTask.Message = switch message {
        case .data(let data): .data(data)
        case .text(let text): .string(text)
        }
        try await task.send(message)
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
#endif
