//
//  GrandSlamClient.swift
//  XKit
//
//  Created by Kabir Oberai on 19/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import Dependencies

struct GrandSlamClient: Sendable {

    private let encoder = PropertyListEncoder()

    private let lookupManager = GrandSlamLookupManager()

    @Dependency(\.anisetteDataProvider) var anisetteDataProvider
    @Dependency(\.httpClient) var httpClient

    init() {}

    func send<R: GrandSlamRequest>(_ request: R) async throws -> R.Decoder.Value {
        let anisetteData = try await anisetteDataProvider.fetchAnisetteData()
        let url = try await lookupManager.fetchURL(forEndpoint: R.endpoint)

        let content = request.content(anisetteData: anisetteData)
        var httpRequest = HTTPRequest(method: content.httpMethod, url: url)
        httpRequest.headerFields[.contentType] = "text/x-xml-plist"
        httpRequest.headerFields[.init(DeviceInfo.clientInfoKey)!] = anisetteData.deviceInfo.clientInfo
        let body: Data? = switch content {
        case .get:
            nil
        case .data(let body, _, .xml):
            try PropertyListSerialization.data(
                fromPropertyList: body, format: .xml, options: 0
            )
        case .data(let body, _, .json):
            try JSONSerialization.data(withJSONObject: body)
        }
        request.configure(request: &httpRequest, anisetteData: anisetteData)

        // GrandSlam doesn't seem to like reused (keep-alive) connections so create a
        // new one for each request. cf https://github.com/rileytestut/AltSign/pull/52
        let resp = try await httpClient.withEphemeralClient {
            try await $0.makeRequest(httpRequest, body: body)
        }
        return try R.Decoder.decode(data: resp.body)
    }

}
