//
//  DeveloperServicesClient.swift
//  Supercharge
//
//  Created by Kabir Oberai on 24/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public final class DeveloperServicesClient {

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

    public let loginToken: DeveloperServicesLoginToken
    public let deviceInfo: DeviceInfo
    public let anisetteDataProvider: AnisetteDataProvider
    private let httpClient: HTTPClientProtocol

    public init(
        loginToken: DeveloperServicesLoginToken,
        deviceInfo: DeviceInfo,
        anisetteProvider: AnisetteDataProvider,
        httpFactory: HTTPClientFactory = defaultHTTPClientFactory
    ) {
        self.loginToken = loginToken
        self.deviceInfo = deviceInfo
        self.anisetteDataProvider = anisetteProvider
        self.httpClient = httpFactory.makeClient()
    }

    private func send<R: DeveloperServicesRequest>(
        _ request: R,
        anisetteData: AnisetteData,
        completion: @escaping (Result<R.Value, Swift.Error>) -> Void
    ) {
        guard let url = request.apiVersion.url(forAction: request.action) else {
            return completion(.failure(Error.malformedRequest))
        }

        var httpRequest = HTTPRequest(url: url, method: "POST")
        let acceptedLanguages = Locale.preferredLanguages.joined(separator: ", ")

        httpRequest.headers["Accept-Language"] = acceptedLanguages
        httpRequest.headers["Accept"] = request.apiVersion.accept
        httpRequest.headers["Content-Type"] = request.apiVersion.contentType
        httpRequest.headers["User-Agent"] = "Xcode"
        request.methodOverride.map { httpRequest.headers["X-HTTP-Method-Override"] = $0 }

        httpRequest.headers[DeviceInfo.xcodeVersionKey] = DeviceInfo.xcodeVersion
        httpRequest.headers[DeviceInfo.clientInfoKey] = deviceInfo.clientInfo.clientString
        httpRequest.headers[DeviceInfo.deviceIDKey] = deviceInfo.deviceID

        httpRequest.headers["X-Apple-I-Identity-Id"] = loginToken.adsid
        httpRequest.headers["X-Apple-App-Info"] = AppTokenKey.xcode.rawValue
        httpRequest.headers["X-Apple-GS-Token"] = loginToken.token

        anisetteData.dictionary.forEach { httpRequest.headers[$0] = $1 }

        do {
            httpRequest.body = try .buffer(request.apiVersion.body(withParameters: request.parameters))
        } catch {
            return completion(.failure(error))
        }

        request.configure(urlRequest: &httpRequest)

        httpClient.makeRequest(httpRequest) { result in
            let decoded: R.Response
            do {
                let resp = try result.get()
                // we don't throw if data is nil because sometimes no data is
                // okay (eg in the case of EmptyResponse)
                let data = resp.body ?? Data()

//                String(data: data, encoding: .utf8).map { print("\(url): \($0)") }

                decoded = try request.apiVersion.decode(response: data)
            } catch {
                return completion(.failure(error))
            }
            request.parse(decoded, completion: completion)
        }
    }

    public func send<R: DeveloperServicesRequest>(
        _ request: R,
        completion: @escaping (Result<R.Value, Swift.Error>) -> Void
    ) {
        anisetteDataProvider.fetchAnisetteData { result in
            guard let anisetteData = result.get(withErrorHandler: completion) else { return }
            self.send(request, anisetteData: anisetteData, completion: completion)
        }
    }

}
