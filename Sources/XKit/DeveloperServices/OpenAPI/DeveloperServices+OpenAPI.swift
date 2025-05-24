import Foundation
import DeveloperAPI
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import Dependencies

extension DeveloperAPIClient {
    @TaskLocal fileprivate static var cursor: [URLQueryItem] = []

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

    /// Perform a paginated request, starting at the page given by `link`.
    ///
    /// `link` should be a URL that contains a `cursor` query parameter. The
    /// cursor will be applied to any requests made inside the closure.
    public static func withNextLink<T>(
        _ link: String?,
        isolation: isolated (any Actor)? = #isolation,
        perform action: () async throws -> T
    ) async throws -> T {
        let cursor: [URLQueryItem]

        if let link {
            guard let components = URLComponents(string: link),
                  let newOffset = components.queryItems?.first(where: { $0.name == "cursor" }),
                  let newLimit = components.queryItems?.first(where: { $0.name == "limit" })
                  else { throw Errors.badNextLink(link) }
            // the next value will contain a cursor (offset) *and* a limit even if we didn't
            // provide a limit in our initial request. we need to include the limit in subsequent
            // requests, otherwise the cursor isn't respected.
            cursor = [newOffset, newLimit]
        } else {
            cursor = []
        }

        return try await $cursor.withValue(cursor) {
            try await action()
        }
    }

    public enum Errors: Error {
        case badNextLink(String)
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

            var items = components.queryItems ?? []
            items.upsertQueryItems(DeveloperAPIClient.cursor + [
                URLQueryItem(name: "teamId", value: authData.teamID.rawValue)
            ])
            components.queryItems = items

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
        var request = request

        let jwt = try await generator.generate()
        request.headerFields[.authorization] = "Bearer \(jwt)"

        let cursor = DeveloperAPIClient.cursor
        if !cursor.isEmpty {
            var components = URLComponents(string: request.path ?? "") ?? .init()
            var items = components.queryItems ?? []
            items.upsertQueryItems(cursor)
            components.queryItems = items
            request.path = components.string
        }

        return try await next(request, body, baseURL)
    }
}

extension [URLQueryItem] {
    fileprivate mutating func upsertQueryItems(_ items: [URLQueryItem]) {
        let newNames = Set(items.map(\.name))
        removeAll { newNames.contains($0.name) }
        append(contentsOf: items)
    }
}
