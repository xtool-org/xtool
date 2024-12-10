import Foundation
import DeveloperAPI
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

extension DeveloperAPIClient {
    public init(
        middlewares: [any ClientMiddleware],
        httpFactory: HTTPClientFactory = defaultHTTPClientFactory
    ) {
        self.init(
            serverURL: try! Servers.Server1.url(),
            configuration: .init(
                dateTranscoder: .iso8601WithFractionalSeconds
            ),
            transport: httpFactory.makeClient().asOpenAPITransport,
            middlewares: middlewares
        )
    }

    public init(
        xcodeAPI: DeveloperAPIXcodeMiddleware,
        httpFactory: HTTPClientFactory = defaultHTTPClientFactory
    ) {
        self.init(
            middlewares: [xcodeAPI],
            httpFactory: httpFactory
        )
    }
}

public struct DeveloperAPIXcodeMiddleware: ClientMiddleware {
    public let loginToken: DeveloperServicesLoginToken
    public let deviceInfo: DeviceInfo
    public let teamID: String
    public let anisetteDataProvider: AnisetteDataProvider

    public init(
        anisetteDataProvider: AnisetteDataProvider,
        loginToken: DeveloperServicesLoginToken,
        deviceInfo: DeviceInfo,
        teamID: String
    ) {
        self.anisetteDataProvider = anisetteDataProvider
        self.loginToken = loginToken
        self.deviceInfo = deviceInfo
        self.teamID = teamID
    }

    private static let baseURL = URL(string: "https://developerservices2.apple.com/services")!
    private static let queryEncoder = JSONEncoder()

    public func intercept(
        _ request: HTTPTypes.HTTPRequest,
        body: OpenAPIRuntime.HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (
            _ request: HTTPTypes.HTTPRequest,
            _ body: OpenAPIRuntime.HTTPBody?,
            _ baseURL: URL
        ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?)
    ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?) {
        var request = request

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
        request.headerFields[.init("X-Apple-I-Identity-Id")!] = loginToken.adsid
        request.headerFields[.init("X-Apple-GS-Token")!] = loginToken.token

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
                URLQueryItem(name: "teamId", value: teamID)
            ]
            let query = components.percentEncodedQuery ?? ""

            components.query = nil
            request.path = components.path

            let bodyData = try Self.queryEncoder.encode(["urlEncodedQueryParams": query])
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

            workingAttributes["teamId"] = teamID
            workingData["attributes"] = workingAttributes
            workingBody["data"] = workingData

            let encodedBody = try JSONSerialization.data(withJSONObject: workingBody)

            body = HTTPBody(encodedBody)
            request.headerFields[.contentLength] = "\(encodedBody.count)"
        default:
            throw Errors.unrecognizedHTTPMethod(originalMethod.rawValue)
        }

        var (response, responseBody) = try await next(request, body, Self.baseURL)

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
