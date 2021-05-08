//
//  URLSession+HTTPClientProtocol.swift
//
//
//  Created by Kabir Oberai on 05/05/21.
//

#if !os(Linux)
import Foundation

public struct UnknownHTTPError: Error {}

extension URLSession: HTTPClientProtocol {
    @discardableResult
    public func makeRequest(
        _ request: HTTPRequest,
        completion: @escaping (Result<HTTPResponse, Error>) -> Void
    ) -> HTTPTask {
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
        let task = dataTask(with: req) { data, resp, error in
            if let error = error {
                return completion(.failure(error))
            }
            guard let httpResp = resp as? HTTPURLResponse else {
                return completion(.failure(UnknownHTTPError()))
            }
            let headers = [String: String](
                uniqueKeysWithValues: httpResp.allHeaderFields.compactMap { k, v in
                    guard let kStr = k as? String,
                          let vStr = v as? String
                    else { return nil }
                    return (kStr, vStr)
                }
            )
            let resp = HTTPResponse(
                url: request.url,
                status: httpResp.statusCode,
                headers: headers,
                body: data
            )
            completion(.success(resp))
        }
        task.resume()
        return HTTPTask { task.cancel() }
    }
}

public final class URLHTTPClientFactory: HTTPClientFactory {
    public static let shared = URLHTTPClientFactory()

    // no need for cert handling since the Apple Root CA is already
    // installed on any devices which support the Security APIs which
    // would have been required to add the custom root anyway
    private let session = URLSession(configuration: .ephemeral)
    private init() {}

    public func shutdown() {}
    public func makeClient() -> HTTPClientProtocol { session }
}
#endif
