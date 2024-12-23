//
//  GrandSlamClient.swift
//  Supersign
//
//  Created by Kabir Oberai on 19/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import Dependencies

struct GrandSlamClient: Sendable {

    private let encoder = PropertyListEncoder()

    private let lookupManager = GrandSlamLookupManager()

    @Dependency(\.deviceInfoProvider) var deviceInfoProvider
    @Dependency(\.anisetteDataProvider) var anisetteDataProvider
    @Dependency(\.httpClient) var httpClient

    init() {}

    func send<R: GrandSlamRequest>(_ request: R) async throws -> R.Decoder.Value {
        let deviceInfo = try deviceInfoProvider.fetch()

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

}
