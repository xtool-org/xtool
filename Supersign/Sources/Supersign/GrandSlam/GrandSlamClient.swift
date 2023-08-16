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
        anisetteProvider: AnisetteDataProvider,
        httpFactory: HTTPClientFactory = defaultHTTPClientFactory
    ) {
        self.deviceInfo = deviceInfo
        self.anisetteDataProvider = anisetteProvider
        self.lookupManager = .init(deviceInfo: deviceInfo, httpFactory: httpFactory)
        self.httpClient = httpFactory.makeClient()
    }

    func send<R: GrandSlamRequest>(_ request: R) async throws -> R.Decoder.Value {
        let anisetteData = try await anisetteDataProvider.fetchAnisetteData()
        let url = try await lookupManager.fetchURL(forEndpoint: R.endpoint)

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
            httpRequest.body = try .buffer(PropertyListSerialization.data(
                fromPropertyList: body, format: .xml, options: 0
            ))
        }
        request.configure(request: &httpRequest, deviceInfo: deviceInfo, anisetteData: anisetteData)

        let resp = try await httpClient.makeRequest(httpRequest)
        return try R.Decoder.decode(data: resp.body ?? .init())
    }

    @available(*, deprecated, message: "Use async overload")
    func send<R: GrandSlamRequest>(_ request: R, completion: @escaping (Result<R.Decoder.Value, Swift.Error>) -> Void) {
        Task { completion(await Result { try await send(request) }) }
    }

}
