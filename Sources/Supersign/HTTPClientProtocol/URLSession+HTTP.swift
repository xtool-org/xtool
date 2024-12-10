//
//  URLSession+HTTPClientProtocol.swift
//
//
//  Created by Kabir Oberai on 05/05/21.
//

#if !os(Linux)
import Foundation
import ConcurrencyExtras
import OpenAPIRuntime
import OpenAPIURLSession

public struct UnknownHTTPError: Error {}

final class URLHTTPClientFactory: HTTPClientFactory {
    static let shared = URLHTTPClientFactory()

    private let client = Client()

    func shutdown() {}
    func makeClient() -> HTTPClientProtocol { client }
}

private final class Client: HTTPClientProtocol {
    final class ClientDelegate: NSObject, URLSessionWebSocketDelegate {
        let webSocketCallbacks = LockIsolated<[
            URLSessionWebSocketTask: @Sendable (URLSessionWebSocketTask.CloseCode?) -> Void
        ]>([:])

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didOpenWithProtocol protocol: String?
        ) {
            webSocketCallbacks.withValue { $0.removeValue(forKey: webSocketTask) }?(nil)
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
            reason: Data?
        ) {
            webSocketCallbacks.withValue { $0.removeValue(forKey: webSocketTask) }?(closeCode)
        }
    }

    private let clientDelegate = ClientDelegate()
    private let session: URLSession

    init() {
        // no need for cert handling since the Apple Root CA is already
        // installed on any devices which support the Security APIs which
        // would have been required to add the custom root anyway
        self.session = URLSession(configuration: .ephemeral, delegate: clientDelegate, delegateQueue: .main)
    }

    var asOpenAPITransport: any ClientTransport {
        URLSessionTransport(configuration: .init(session: session))
    }

    public func makeRequest(
        _ request: HTTPRequest,
        onProgress: sending @isolated(any) (Double?) -> Void
    ) async throws -> HTTPResponse {
        final class ProgressDelegate: NSObject, URLSessionDataDelegate {
            private let progressContinuation: AsyncStream<Double>.Continuation
            let progressStream: AsyncStream<Double>

            @MainActor private var count = 0

            override init() {
                (progressStream, progressContinuation) = AsyncStream<Double>.makeStream(
                    // it's okay to skip missed progress updates
                    bufferingPolicy: .bufferingNewest(1)
                )
            }

            func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
                let count = MainActor.assumeIsolated {
                    self.count += data.count
                    return self.count
                }
                if let contentLength = dataTask.response?.expectedContentLength, contentLength != -1 {
                    let progress = min(Double(count) / Double(contentLength), 1)
                    progressContinuation.yield(progress)
                }
            }

            func finish() {
                progressContinuation.finish()
            }
        }

        var req = URLRequest(url: request.url)
        req.httpMethod = request.method
        request.headers.forEach { k, v in
            req.setValue(v, forHTTPHeaderField: k)
        }
        switch request.body {
        case .buffer(let data):
            req.httpBody = data
        case nil:
            break
        }

        let delegate = ProgressDelegate()
        async let progressWatcher: Void = {
            for await progress in delegate.progressStream {
                await onProgress(progress)
            }
        }()
        let (data, response) = if #available(macOS 12, iOS 15, tvOS 15, watchOS 8, *) {
            try await session.data(for: req, delegate: delegate)
        } else {
            try await session.data(for: req)
        }
        delegate.finish()
        _ = await progressWatcher

        guard let httpResp = response as? HTTPURLResponse else { throw UnknownHTTPError() }
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
        let (event, eventContinuation) = AsyncStream<URLSessionWebSocketTask.CloseCode?>.makeStream()
        clientDelegate.webSocketCallbacks.withValue {
            $0[task] = {
                eventContinuation.yield($0)
                eventContinuation.finish()
            }
        }
        let code = await event.first { _ in true } ?? nil
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

extension Optional {
    fileprivate mutating func inoutMap<E>(_ transform: (inout Wrapped) throws(E) -> Void) throws(E) {
        if self != nil { try transform(&self!) }
    }
}

#endif
