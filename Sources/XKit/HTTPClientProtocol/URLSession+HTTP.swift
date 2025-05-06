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
import Dependencies

public struct UnknownHTTPError: Error {}

extension HTTPClientDependencyKey: DependencyKey {
    public static let liveValue: HTTPClientProtocol = Client()
}

private struct Client: HTTPClientProtocol {
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

    public func makeWebSocket(url: URL) async throws -> any WebSocketSession {
        let task = session.webSocketTask(with: url)
        let (event, eventContinuation) = AsyncStream<URLSessionWebSocketTask.CloseCode?>.makeStream()
        clientDelegate.webSocketCallbacks.withValue {
            $0[task] = {
                eventContinuation.yield($0)
                eventContinuation.finish()
            }
        }
        task.resume()
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
