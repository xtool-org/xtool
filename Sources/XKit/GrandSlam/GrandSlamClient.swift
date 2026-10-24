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

        let method = request.method(anisetteData: anisetteData)
        var httpRequest = HTTPRequest(method: method.httpMethod, url: url)
        httpRequest.headerFields[.contentType] = "text/x-xml-plist"
        httpRequest.headerFields[.init(DeviceInfo.clientInfoKey)!] = anisetteData.deviceInfo.clientInfo
        let body: Data? = switch method {
        case .get:
            nil
        case .post(let body):
            try PropertyListSerialization.data(
                fromPropertyList: body, format: .xml, options: 0
            )
        }
        request.configure(request: &httpRequest, anisetteData: anisetteData)

        // Only emit the request type and HTTP status, never headers or response bodies:
        // those may contain credentials, verification data, or session tokens.
        let traceEnabled = ProcessInfo.processInfo.environment["XTL_GSA_TRACE"] == "1"

        // GrandSlam doesn't seem to like reused (keep-alive) connections so create a
        // new one for each request. cf https://github.com/rileytestut/AltSign/pull/52
        do {
            let resp = try await httpClient.withEphemeralClient {
                try await $0.makeRequest(httpRequest, body: body)
            }
            if traceEnabled {
                print("GrandSlam \(R.self): HTTP \(resp.response.status.code)")
            }
            return try R.Decoder.decode(data: resp.body)
        } catch let error as HTTPResponseError {
            if traceEnabled {
                print("GrandSlam \(R.self): HTTP \(error.status.code)")
            }
            throw error
        }
    }

}
