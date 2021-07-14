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

extension HTTPClient: HTTPClientProtocol {
//    private struct ReadError: Error {}
//
//    private func read(
//        inputStream stream: InputStream,
//        chunkSize: Int,
//        eventLoop: EventLoop,
//        writer: @escaping (ByteBuffer) -> EventLoopFuture<Void>
//    ) -> EventLoopFuture<Void> {
//        var buf = ByteBuffer()
//        func _read() -> EventLoopFuture<Void> {
//            eventLoop.submit { () throws -> Int in
//                buf.clear()
//                return try buf.writeWithUnsafeMutableBytes(minimumWritableBytes: chunkSize) { raw in
//                    let bound = raw.bindMemory(to: UInt8.self)
//                    let res = stream.read(bound.baseAddress!, maxLength: bound.count)
//                    guard res != -1 else { throw ReadError() }
//                    return res
//                }
//            }.flatMap { bytesRead in
//                bytesRead == 0 ?
//                    // we've reached the EOF
//                    writer(buf) :
//                    // there's more. Write and then keep reading.
//                    writer(buf).flatMap(_read)
//            }
//        }
//        return _read()
//    }

    @discardableResult
    public func makeRequest(
        _ request: HTTPRequest,
        completion: @escaping (Result<HTTPResponse, Error>) -> Void
    ) -> HTTPTask {
//        print("Requesting \(request.url)")

        let headers = HTTPHeaders(request.headers.map { $0 })
        let body: HTTPClient.Body?
        switch request.body {
        case .buffer(let data):
            body = .data(data)
//        case .stream(let stream):
//            body = .stream { writer in
//                let eventLoop = writer.write(.byteBuffer(.init())).eventLoop
//                return self.read(inputStream: stream, chunkSize: 1024, eventLoop: eventLoop) {
//                    writer.write(.byteBuffer($0))
//                }
//            }
        case nil:
            body = nil
        }
        let httpReq: HTTPClient.Request
        do {
            httpReq = try HTTPClient.Request(
                url: request.url,
                method: request.method.map(HTTPMethod.init(rawValue:)) ?? .GET,
                headers: headers,
                body: body
            )
        } catch {
            completion(.failure(error))
            return HTTPTask { }
        }
        let task = execute(request: httpReq, delegate: ResponseAccumulator(request: httpReq))
        task.futureResult.map { result in
            HTTPResponse(
                url: request.url,
                status: Int(result.status.code),
                headers: [String: String](uniqueKeysWithValues: result.headers.map { $0 }),
                body: result.body.flatMap { $0.getData(at: 0, length: $0.writerIndex) }
            )
        }.whenComplete(completion)
        return HTTPTask { task.cancel() }
    }
}

final class AsyncHTTPClientFactory: HTTPClientFactory {
    private static let appleRootPEM = """
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

    private let client: HTTPClient
    private init() {
        // if ssl cert parsing fails we're screwed so we might as well force try
        let appleRootCA = try! NIOSSLCertificate(bytes: Array(Self.appleRootPEM.utf8), format: .pem)
        let config = HTTPClient.Configuration(
            tlsConfiguration: .forClient(additionalTrustRoots: [.certificates([appleRootCA])]),
            decompression: .enabled(limit: .none)
        )
        client = HTTPClient(eventLoopGroupProvider: .createNew, configuration: config)
    }
    static let shared = AsyncHTTPClientFactory()

    func shutdown() {
        try! client.syncShutdown()
    }

    func makeClient() -> HTTPClientProtocol { client }
}
#endif
