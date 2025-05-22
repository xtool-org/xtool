import Foundation
import DeveloperAPI
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import Dependencies

extension DeveloperAPIClient {
    public init(
        auth: DeveloperAPIAuthData
    ) {
        @Dependency(\.httpClient) var httpClient
        self.init(
            serverURL: try! Servers.Server1.url(),
            configuration: .init(
                dateTranscoder: .iso8601WithFractionalSeconds
            ),
            transport: httpClient.asOpenAPITransport,
            middlewares: [
                auth.middleware,
                LoggingMiddleware(),
            ]
        )
    }
}

public enum DeveloperAPIAuthData: Sendable {
    case appStoreConnect(ASCKey)
    case xcode(XcodeAuthData)

    fileprivate var middleware: ClientMiddleware {
        switch self {
        case .appStoreConnect(let key):
            DeveloperAPIASCAuthMiddleware(key: key)
        case .xcode(let authData):
            DeveloperAPIXcodeAuthMiddleware(authData: authData)
        }
    }

    // A unique ID tied to this token
    public var identityID: String {
        switch self {
        case .appStoreConnect(let key):
            key.issuerID
        case .xcode(let data):
            data.teamID.rawValue
        }
    }
}

public struct XcodeAuthData: Sendable {
    public var loginToken: DeveloperServicesLoginToken
    public var teamID: DeveloperServicesTeam.ID

    public init(
        loginToken: DeveloperServicesLoginToken,
        teamID: DeveloperServicesTeam.ID
    ) {
        self.loginToken = loginToken
        self.teamID = teamID
    }
}

public struct DeveloperAPIXcodeAuthMiddleware: ClientMiddleware {
    @Dependency(\.deviceInfoProvider) private var deviceInfoProvider
    @Dependency(\.anisetteDataProvider) private var anisetteDataProvider

    public var authData: XcodeAuthData

    public init(authData: XcodeAuthData) {
        self.authData = authData
    }

    private static let baseURL = URL(string: "https://developerservices2.apple.com/services")!
    private static let queryEncoder = JSONEncoder()

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (
            _ request: HTTPRequest,
            _ body: HTTPBody?,
            _ baseURL: URL
        ) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request

        let deviceInfo = try deviceInfoProvider.fetch()

        // General
        request.headerFields[.acceptLanguage] = Locale.preferredLanguages.joined(separator: ", ")
        request.headerFields[.accept] = "application/vnd.api+json"
        request.headerFields[.contentType] = "application/vnd.api+json"
        request.headerFields[.acceptEncoding] = "gzip, deflate"

        // Xcode-specific
        request.headerFields[.userAgent] = "Xcode"
        request.headerFields[.init(DeviceInfo.xcodeVersionKey)!] = "16.2 (16C5031c)"

        // MobileMe identity
        request.headerFields[.init(DeviceInfo.clientInfoKey)!] = """
        <VirtualMac2,1> <macOS;15.1.1;24B91> <com.apple.AuthKit/1 (com.apple.dt.Xcode/23505)>
        """ // deviceInfo.clientInfo.clientString
        request.headerFields[.init(DeviceInfo.deviceIDKey)!] = deviceInfo.deviceID

        // GrandSlam authentication
        request.headerFields[.init("X-Apple-App-Info")!] = AppTokenKey.xcode.rawValue
        request.headerFields[.init("X-Apple-I-Identity-Id")!] = authData.loginToken.adsid
        request.headerFields[.init("X-Apple-GS-Token")!] = authData.loginToken.token

        // Anisette
        let anisetteData = try await anisetteDataProvider.fetchAnisetteData()
        for (key, value) in anisetteData.dictionary {
            request.headerFields[.init(key)!] = value
        }

        // Body
        var body = body
        let originalMethod = request.method
        switch originalMethod {
        case .get, .delete:
            request.headerFields[.init("X-HTTP-Method-Override")!] = originalMethod.rawValue
            request.method = .post

            let path = request.path ?? "/"
            var components = URLComponents(string: path) ?? .init()
            components.queryItems = (components.queryItems ?? []) + [
                URLQueryItem(name: "teamId", value: authData.teamID.rawValue)
            ]
            let query = components.percentEncodedQuery ?? ""

            components.query = nil
            request.path = components.path

            let bodyData = try DeveloperAPIXcodeAuthMiddleware.queryEncoder.encode(["urlEncodedQueryParams": query])
            body = HTTPBody(bodyData)
        case .patch, .post:
            // set .data.attributes.teamId = teamID

            var workingBody: [String: Any] = [:]
            if let existingBody = body {
                let data = try await Data(collecting: existingBody, upTo: .max)
                guard let decodedBody = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw Errors.malformedPayload("body")
                }
                workingBody = decodedBody
            }

            var workingData: [String: Any] = [:]
            if let existingData = workingBody["data"] {
                guard let decodedData = existingData as? [String: Any] else {
                    throw Errors.malformedPayload("data")
                }
                workingData = decodedData
            }

            var workingAttributes: [String: Any] = [:]
            if let existingAttributes = workingData["attributes"] {
                guard let decodedAttributes = existingAttributes as? [String: Any] else {
                    throw Errors.malformedPayload("attributes")
                }
                workingAttributes = decodedAttributes
            }

            workingAttributes["teamId"] = authData.teamID.rawValue
            workingData["attributes"] = workingAttributes
            workingBody["data"] = workingData

            let encodedBody = try JSONSerialization.data(withJSONObject: workingBody)

            body = HTTPBody(encodedBody)
            request.headerFields[.contentLength] = "\(encodedBody.count)"
        default:
            throw Errors.unrecognizedHTTPMethod(originalMethod.rawValue)
        }

        var (response, responseBody) = try await next(request, body, DeveloperAPIXcodeAuthMiddleware.baseURL)

        if response.headerFields[.contentType] == "application/vnd.api+json" {
            response.headerFields[.contentType] = "application/json"
        }

        return (response, responseBody)
    }

    public enum Errors: Error {
        case unrecognizedHTTPMethod(String)
        case malformedPayload(String)
    }
}

public struct DeveloperAPIASCAuthMiddleware: ClientMiddleware {
    private var generator: ASCJWTGenerator

    public var key: ASCKey {
        get { generator.key }
        set { generator = ASCJWTGenerator(key: newValue) }
    }

    public init(key: ASCKey) {
        generator = ASCJWTGenerator(key: key)
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (
            _ request: HTTPRequest,
            _ body: HTTPBody?,
            _ baseURL: URL
        ) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let jwt = try await generator.generate()
        var request = request
        request.headerFields[.authorization] = "Bearer \(jwt)"
        return try await next(request, body, baseURL)
    }
}

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
