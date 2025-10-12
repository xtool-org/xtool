//
//  GrandSlamLookupManager.swift
//  XKit
//
//  Created by Kabir Oberai on 19/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import Dependencies
import HTTPTypesFoundation

actor GrandSlamLookupManager {

    private static let lookupURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!

    private struct Response: Decodable {
        let urls: GrandSlamEndpoints
    }

    private let decoder = PropertyListDecoder()
    private var endpoints: GrandSlamEndpoints?

    @Dependency(\.deviceInfoProvider) var deviceInfoProvider
    @Dependency(\.httpClient) var httpClient

    init() {}

    private func performLookup() async throws -> GrandSlamEndpoints {
        let deviceInfo = try deviceInfoProvider.fetch()

        /* {
            "X-Apple-I-Locale" = "en_IN";
            "X-Apple-I-TimeZone" = "Asia/Kolkata";
            "X-Apple-I-TimeZone-Offset" = 19800;
            "X-MMe-Client-Info" = "<MacBookPro11,5> <Mac OS X;10.14.6;18G103> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
            "X-MMe-Country" = IN;
            "X-Mme-Device-Id" = "[REDACTED]";
        } */
        var request = HTTPRequest(url: Self.lookupURL)
        request.headerFields = [
            .init(DeviceInfo.clientInfoKey)!: deviceInfo.clientInfo.clientString,
            .init(DeviceInfo.deviceIDKey)!: deviceInfo.deviceID,
            .init(AnisetteData.iLocaleKey)!: Locale.current.identifier,
            .init(AnisetteData.timeZoneKey)!: TimeZone.current.identifier,
            .init("X-Apple-I-TimeZone-Offset")!: "\(TimeZone.current.secondsFromGMT())"
        ]
        request.headerFields[.init("X-MMe-Country")!] = Locale.current.region?.identifier

        let (_, body) = try await httpClient.makeRequest(request)

        return try self.decoder.decode(Response.self, from: body).urls
    }

    private func fetchEndpoints() async throws -> GrandSlamEndpoints {
        if let endpoints = endpoints { return endpoints }
        let endpoints = try await performLookup()
        self.endpoints = endpoints
        return endpoints
    }

    func fetchURL(forEndpoint endpoint: GrandSlamEndpoint) async throws -> URL {
        switch endpoint {
        case .lookup(let keyPath):
            let endpoints = try await fetchEndpoints()
            return URL(string: endpoints[keyPath: keyPath])!
        case .url(let url):
            return url
        }
    }

}
