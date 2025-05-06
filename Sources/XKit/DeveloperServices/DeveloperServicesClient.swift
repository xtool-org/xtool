//
//  DeveloperServicesClient.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import Dependencies

public struct DeveloperServicesClient: Sendable {

    public enum Error: LocalizedError {
        case noData
        case malformedRequest
        case apiError(code: Int, reason: String?)

        public var errorDescription: String? {
            switch self {
            case .noData:
                return NSLocalizedString(
                    "developer_services_client.error.no_data", value: "No data", comment: ""
                )
            case .malformedRequest:
                return NSLocalizedString(
                    "developer_services_client.error.malformed_request", value: "Malformed request", comment: ""
                )
            case .apiError(let code, let reason?):
                return reason.withCString { reasonC in
                    "\(code)".withCString { codeC in
                        String.localizedStringWithFormat(
                            NSLocalizedString(
                                "developer_services_client.error.sign_in_error.reason_and_code",
                                value: "%s (%s)",
                                comment: "First reason, then code"
                            ),
                            reasonC, codeC
                        )
                    }
                }
            case .apiError(let code, _):
                return "\(code)".withCString {
                    String.localizedStringWithFormat(
                        NSLocalizedString(
                            "developer_services_client.error.sign_in_error.only_code",
                            value: "An unknown error occurred (%s)",
                            comment: ""
                        ),
                        $0
                    )
                }
            }
        }
    }

    @Dependency(\.deviceInfoProvider) var deviceInfoProvider
    @Dependency(\.anisetteDataProvider) var anisetteDataProvider
    @Dependency(\.httpClient) var httpClient

    public let loginToken: DeveloperServicesLoginToken

    public init(loginToken: DeveloperServicesLoginToken) {
        self.loginToken = loginToken
    }

    public init(authData: XcodeAuthData) {
        self.loginToken = authData.loginToken
    }

    private func send<R: DeveloperServicesRequest>(
        _ request: R,
        anisetteData: AnisetteData
    ) async throws -> R.Value {
        guard let url = request.apiVersion.url(forAction: request.action) else {
            throw Error.malformedRequest
        }

        let deviceInfo = try deviceInfoProvider.fetch()

        var httpRequest = HTTPRequest(method: .post, url: url)
        let acceptedLanguages = Locale.preferredLanguages.joined(separator: ", ")

        httpRequest.headerFields[.acceptLanguage] = acceptedLanguages
        httpRequest.headerFields[.accept] = request.apiVersion.accept
        httpRequest.headerFields[.contentType] = request.apiVersion.contentType
        httpRequest.headerFields[.userAgent] = "Xcode"
        request.methodOverride.map { httpRequest.headerFields[.init("X-HTTP-Method-Override")!] = $0 }

        httpRequest.headerFields[.init(DeviceInfo.xcodeVersionKey)!] = DeviceInfo.xcodeVersion
        httpRequest.headerFields[.init(DeviceInfo.clientInfoKey)!] = deviceInfo.clientInfo.clientString
        httpRequest.headerFields[.init(DeviceInfo.deviceIDKey)!] = deviceInfo.deviceID

        httpRequest.headerFields[.init("X-Apple-I-Identity-Id")!] = loginToken.adsid
        httpRequest.headerFields[.init("X-Apple-App-Info")!] = AppTokenKey.xcode.rawValue
        httpRequest.headerFields[.init("X-Apple-GS-Token")!] = loginToken.token

        anisetteData.dictionary.forEach { httpRequest.headerFields[.init($0)!] = $1 }

        request.configure(urlRequest: &httpRequest)

        let body = try request.apiVersion.body(withParameters: request.parameters)

        let (_, data) = try await httpClient.makeRequest(httpRequest, body: body)

//        String(data: data, encoding: .utf8).map { print("\(url): \($0)") }

        let decoded: R.Response = try request.apiVersion.decode(response: data)

        return try await request.parse(decoded)
    }

    public func send<R: DeveloperServicesRequest>(_ request: R) async throws -> R.Value {
        let anisetteData = try await anisetteDataProvider.fetchAnisetteData()
        return try await self.send(request, anisetteData: anisetteData)
    }

}
