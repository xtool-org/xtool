import Foundation
import OpenAPIRuntime
import HTTPTypes

struct LoggingMiddleware: ClientMiddleware {
    static let regex: NSRegularExpression? = {
        guard let pat = ProcessInfo.processInfo.environment["XTL_DEV_LOG"] else { return nil }
        return try? NSRegularExpression(pattern: pat)
    }()

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var (response, body) = try await next(request, body, baseURL)

        guard Self.regex?.firstMatch(
                  in: operationID,
                  range: NSRange(operationID.startIndex..., in: operationID)
              ) != nil
              else { return (response, body) }

        print("\n\(operationID) response status -> \(response.status)")

        if let unwrapped = body {
            let data = try await Data(collecting: unwrapped, upTo: .max)
            // body may only be consumable once, replace it with the collected data
            body = .init(data)

            let text = String(decoding: data, as: UTF8.self)
            print("\(operationID) response body -> \(text)")
        }

        return (response, body)
    }
}
