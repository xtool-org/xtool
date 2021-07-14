//
//  GrandSlamClient.swift
//  Supersign
//
//  Created by Kabir Oberai on 19/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

class GrandSlamClient {

    private let encoder = PropertyListEncoder()

    private let lookupManager: GrandSlamLookupManager

    let deviceInfo: DeviceInfo
    let anisetteDataProvider: AnisetteDataProvider
    private let httpClient: HTTPClientProtocol
    init(
        deviceInfo: DeviceInfo,
        httpFactory: HTTPClientFactory = defaultHTTPClientFactory,
        customAnisetteDataProvider: AnisetteDataProvider? = nil
    ) {
        self.deviceInfo = deviceInfo
        self.anisetteDataProvider = customAnisetteDataProvider
            ?? SupersetteDataProvider(deviceInfo: deviceInfo)
        self.lookupManager = .init(deviceInfo: deviceInfo, httpFactory: httpFactory)
        self.httpClient = httpFactory.makeClient()
    }

    private func send<R: GrandSlamRequest>(
        _ request: R,
        anisetteData: AnisetteData,
        url: URL,
        completion: @escaping (Result<R.Decoder.Value, Swift.Error>) -> Void
    ) {
        let method = request.method(deviceInfo: deviceInfo, anisetteData: anisetteData)
        var httpRequest = HTTPRequest(url: url, method: method.name)
        httpRequest.headers = [
            "Content-Type": "text/x-xml-plist",
            DeviceInfo.clientInfoKey: deviceInfo.clientInfo.clientString
        ]
        switch method {
        case .get:
            break
        case .post(let body):
            do {
                httpRequest.body = try .buffer(PropertyListSerialization.data(
                    fromPropertyList: body, format: .xml, options: 0
                ))
            } catch {
                return completion(.failure(error))
            }
        }
        request.configure(request: &httpRequest, deviceInfo: deviceInfo, anisetteData: anisetteData)

        httpClient.makeRequest(httpRequest) { result in
            guard let resp = result.get(withErrorHandler: completion) else { return }
            completion(Result {
                try R.Decoder.decode(data: resp.body ?? .init())
            })
        }
    }

    private func send<R: GrandSlamRequest>(
        _ request: R,
        anisetteData: AnisetteData,
        completion: @escaping (Result<R.Decoder.Value, Swift.Error>) -> Void
    ) {
        lookupManager.fetchURL(forEndpoint: R.endpoint) { result in
            guard let url = result.get(withErrorHandler: completion) else { return }
            self.send(request, anisetteData: anisetteData, url: url, completion: completion)
        }
    }

    func send<R: GrandSlamRequest>(
        _ request: R,
        completion: @escaping (Result<R.Decoder.Value, Swift.Error>) -> Void
    ) {
        self.anisetteDataProvider.fetchAnisetteData { result in
            guard let anisetteData = result.get(withErrorHandler: completion) else { return }
            self.send(request, anisetteData: anisetteData, completion: completion)
        }
    }

}
