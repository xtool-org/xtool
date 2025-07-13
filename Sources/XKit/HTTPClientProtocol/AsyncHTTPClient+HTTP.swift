//
//  AsyncHTTPClient+HTTP.swift
//
//
//  Created by Kabir Oberai on 05/05/21.
//

#if os(Linux)
import Foundation
import AsyncHTTPClient
import NIO
import NIOHTTP1
import NIOSSL
import NIOFoundationCompat
import WebSocketKit
import OpenAPIRuntime
import OpenAPIAsyncHTTPClient
import Dependencies

extension HTTPClientDependencyKey: DependencyKey {
    public static let liveValue: HTTPClientProtocol = {
        // if ssl cert parsing fails we're screwed so we might as well force try
        // swiftlint:disable:next force_try
        let appleRootCA = try! NIOSSLCertificate(bytes: Array(appleRootPEM.utf8), format: .pem)
        var tlsConfiguration: TLSConfiguration = .makeClientConfiguration()
        tlsConfiguration.additionalTrustRoots = [.certificates([appleRootCA])]
        var config = HTTPClient.Configuration(
            tlsConfiguration: tlsConfiguration,
            decompression: .enabled(limit: .none)
        )
        config.timeout.connect = .seconds(60)
        return HTTPClient(configuration: config)
    }()
}

extension HTTPClient: HTTPClientProtocol {
    public func makeWebSocket(url: URL) async throws -> any WebSocketSession {
        let (stream, continuation) = AsyncStream.makeStream(of: WebSocketSessionWrapper.self)
        async let value = stream.first(where: { _ in true })
        // must be after the `async let` so that we finish if connect throws
        defer { continuation.finish() }
        // we can't use the async overload because we need to immediately subscribe
        // to onText/onBinary in the same EventLoop tick that the WebSocket is created.
        // This is also why we create the SessionWrapper inside the closure.
        let future = WebSocket.connect(to: url, on: eventLoopGroup) {
            continuation.yield(WebSocketSessionWrapper(webSocket: $0))
        }
        try await future.get()
        guard let webSocket = await value else {
            throw Errors.connectFailed
        }
        return webSocket
    }

    private enum Errors: Error {
        case connectFailed
    }

    public var asOpenAPITransport: any ClientTransport {
        AsyncHTTPClientTransport(configuration: .init(client: self))
    }
}

private final class WebSocketSessionWrapper: WebSocketSession {
    let webSocket: WebSocket
    let stream: AsyncStream<WebSocketMessage>
    private let finishStream: @Sendable () -> Void

    init(webSocket: WebSocket) {
        self.webSocket = webSocket

        let (stream, continuation) = AsyncStream<WebSocketMessage>.makeStream(bufferingPolicy: .unbounded)
        self.stream = stream
        self.finishStream = { continuation.finish() }
        webSocket.onText { _, text in
            continuation.yield(.text(text))
        }
        webSocket.onBinary { _, data in
            continuation.yield(.data(Data(data.readableBytesView)))
        }
    }

    deinit {
        close()
    }

    func close() {
        finishStream()
        Task { [webSocket] in try? await webSocket.close() }
    }

    func send(_ message: WebSocketMessage) async throws {
        switch message {
        case .text(let text):
            try await webSocket.send(text)
        case .data(let data):
            try await webSocket.send(.init(data))
        }
    }

    func receive() async throws -> WebSocketMessage {
        await stream.first(where: { _ in true }) ?? .data(Data())
    }
}

private let appleRootPEM = """
-----BEGIN CERTIFICATE-----
MIIEuzCCA6OgAwIBAgIBAjANBgkqhkiG9w0BAQUFADBiMQswCQYDVQQGEwJVUzET
MBEGA1UEChMKQXBwbGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlv
biBBdXRob3JpdHkxFjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwHhcNMDYwNDI1MjE0
MDM2WhcNMzUwMjA5MjE0MDM2WjBiMQswCQYDVQQGEwJVUzETMBEGA1UEChMKQXBw
bGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkx
FjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAw
ggEKAoIBAQDkkakJH5HbHkdQ6wXtXnmELes2oldMVeyLGYne+Uts9QerIjAC6Bg+
+FAJ039BqJj50cpmnCRrEdCju+QbKsMflZ56DKRHi1vUFjczy8QPTc4UadHJGXL1
XQ7Vf1+b8iUDulWPTV0N8WQ1IxVLFVkds5T39pyez1C6wVhQZ48ItCD3y6wsIG9w
tj8BMIy3Q88PnT3zK0koGsj+zrW5DtleHNbLPbU6rfQPDgCSC7EhFi501TwN22IW
q6NxkkdTVcGvL0Gz+PvjcM3mo0xFfh9Ma1CWQYnEdGILEINBhzOKgbEwWOxaBDKM
aLOPHd5lc/9nXmW8Sdh2nzMUZaF3lMktAgMBAAGjggF6MIIBdjAOBgNVHQ8BAf8E
BAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUK9BpR5R2Cf70a40uQKb3
R01/CF4wHwYDVR0jBBgwFoAUK9BpR5R2Cf70a40uQKb3R01/CF4wggERBgNVHSAE
ggEIMIIBBDCCAQAGCSqGSIb3Y2QFATCB8jAqBggrBgEFBQcCARYeaHR0cHM6Ly93
d3cuYXBwbGUuY29tL2FwcGxlY2EvMIHDBggrBgEFBQcCAjCBthqBs1JlbGlhbmNl
IG9uIHRoaXMgY2VydGlmaWNhdGUgYnkgYW55IHBhcnR5IGFzc3VtZXMgYWNjZXB0
YW5jZSBvZiB0aGUgdGhlbiBhcHBsaWNhYmxlIHN0YW5kYXJkIHRlcm1zIGFuZCBj
b25kaXRpb25zIG9mIHVzZSwgY2VydGlmaWNhdGUgcG9saWN5IGFuZCBjZXJ0aWZp
Y2F0aW9uIHByYWN0aWNlIHN0YXRlbWVudHMuMA0GCSqGSIb3DQEBBQUAA4IBAQBc
NplMLXi37Yyb3PN3m/J20ncwT8EfhYOFG5k9RzfyqZtAjizUsZAS2L70c5vu0mQP
y3lPNNiiPvl4/2vIB+x9OYOLUyDTOMSxv5pPCmv/K/xZpwUJfBdAVhEedNO3iyM7
R6PVbyTi69G3cN8PReEnyvFteO3ntRcXqNx+IjXKJdXZD9Zr1KIkIxH3oayPc4Fg
xhtbCS+SsvhESPBgOJ4V9T0mZyCKM2r3DYLP3uujL/lTaltkwGMzd/c6ByxW69oP
IQ7aunMZT7XZNn/Bh1XZp5m5MkL72NVxnn6hUrcbvZNCJBIqxw8dtk2cXmPIS4AX
UKqK1drk/NAJBzewdXUh
-----END CERTIFICATE-----
"""
#endif
