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
    init(
        deviceInfo: DeviceInfo,
        customAnisetteDataProvider: AnisetteDataProvider? = nil
    ) {
        self.deviceInfo = deviceInfo
        self.anisetteDataProvider = customAnisetteDataProvider
            ?? SupersetteDataProvider(deviceInfo: deviceInfo)
        self.lookupManager = .init(deviceInfo: deviceInfo)
    }

    private func send<R: GrandSlamRequest>(
        _ request: R,
        anisetteData: AnisetteData,
        url: URL,
        completion: @escaping (Result<R.Decoder.Value, Swift.Error>) -> Void
    ) {
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(deviceInfo.clientInfo.clientString, forHTTPHeaderField: DeviceInfo.clientInfoKey)

        let method = request.method(deviceInfo: deviceInfo, anisetteData: anisetteData)
        urlRequest.httpMethod = method.name
        switch method {
        case .get:
            break
        case .post(let body):
            do {
                urlRequest.httpBody = try PropertyListSerialization.data(
                    fromPropertyList: body, format: .xml, options: 0
                )
            } catch {
                return completion(.failure(error))
            }
        }
        request.configure(request: &urlRequest, deviceInfo: deviceInfo, anisetteData: anisetteData)

        URLSession.shared.dataTask(with: urlRequest) { data, _, error in
//            print(response.map(String.init(describing:)) ?? "NO RESPONSE")
            if let error = error {
                return completion(.failure(error))
            }
            completion(Result {
                try R.Decoder.decode(data: data ?? .init())
            })
        }.resume()
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
