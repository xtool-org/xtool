//
//  GrandSlamLookupManager.swift
//  Supersign
//
//  Created by Kabir Oberai on 19/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

class GrandSlamLookupManager {

    private static let lookupURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!

    private struct Response: Decodable {
        let urls: GrandSlamEndpoints
    }

    private let decoder = PropertyListDecoder()
    private var endpoints: GrandSlamEndpoints?

    let deviceInfo: DeviceInfo
    init(deviceInfo: DeviceInfo) {
        self.deviceInfo = deviceInfo
    }

    private func performLookup(completion: @escaping (Result<GrandSlamEndpoints, Error>) -> Void) {
        /* {
            "X-Apple-I-Locale" = "en_IN";
            "X-Apple-I-TimeZone" = "Asia/Kolkata";
            "X-Apple-I-TimeZone-Offset" = 19800;
            "X-MMe-Client-Info" = "<MacBookPro11,5> <Mac OS X;10.14.6;18G103> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
            "X-MMe-Country" = IN;
            "X-Mme-Device-Id" = "[REDACTED]";
        } */
        var request = URLRequest(url: Self.lookupURL)
        request.setValue(deviceInfo.clientInfo.clientString, forHTTPHeaderField: DeviceInfo.clientInfoKey)
        request.setValue(deviceInfo.deviceID, forHTTPHeaderField: DeviceInfo.deviceIDKey)
        request.setValue(Locale.current.regionCode, forHTTPHeaderField: "X-MMe-Country")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: AnisetteData.iLocaleKey)
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: AnisetteData.timeZoneKey)
        request.setValue("\(TimeZone.current.secondsFromGMT())", forHTTPHeaderField: "X-Apple-I-TimeZone-Offset")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                return completion(.failure(error))
            }

            completion(Result {
                try self.decoder.decode(Response.self, from: data ?? .init()).urls
            })
        }.resume()
    }

    private func fetchEndpoints(completion: @escaping (Result<GrandSlamEndpoints, Error>) -> Void) {
        if let endpoints = endpoints {
            return completion(.success(endpoints))
        }
        performLookup { result in
            if case let .success(endpoints) = result {
                self.endpoints = endpoints
            }
            completion(result)
        }
    }

    func fetchURL(
        forEndpoint endpoint: GrandSlamEndpoint,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        fetchEndpoints { result in
            completion(result.map { URL(string: $0[keyPath: endpoint])! })
        }
    }

}
