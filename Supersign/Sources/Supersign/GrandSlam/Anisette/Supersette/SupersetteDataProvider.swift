//
//  SupersetteDataProvider.swift
//  Supersign
//
//  Created by Kabir Oberai on 14/06/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import Foundation

public class SupersetteDataProvider: AnisetteDataProvider {

    private static let gateway = URL(string: "https://anisette.supercharge.app:8443/v1/generate")!

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public enum Error: Swift.Error {
        case networkError
        case invalidAnisetteData
    }

    public let deviceInfo: DeviceInfo
    private let httpClient: HTTPClientProtocol

    public init(deviceInfo: DeviceInfo, httpFactory: HTTPClientFactory.Type = defaultHTTPClientFactory) {
        self.deviceInfo = deviceInfo
        self.httpClient = httpFactory.shared.makeClient()
    }

    private struct AnisetteRequestBody: Encodable {
        let deviceID: String
        let clientInfo: String
    }

    private struct AnisetteResponse: Decodable {
        let routingInfo: UInt64
        let machineID: String
        let localUserID: String
        let oneTimePassword: String
    }

    public func fetchAnisetteData(completion: @escaping (Result<AnisetteData, Swift.Error>) -> Void) {
        let clientTime = Date()
        var request = HTTPRequest(url: Self.gateway, method: "POST")
        request.headers = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Superpass": "BF95B548-3C87-4BBD-8B96-534421368416"
        ]
        do {
            request.body = try .buffer(Self.encoder.encode(AnisetteRequestBody(
                deviceID: deviceInfo.deviceID,
                clientInfo: deviceInfo.clientInfo.clientString
            )))
        } catch {
            return completion(.failure(error))
        }
        httpClient.makeRequest(request) { result in
            completion(Result {
                let resp = try result.get()
                let data = try resp.body.orThrow(Error.invalidAnisetteData)
                let anisetteResponse = try Self.decoder.decode(AnisetteResponse.self, from: data)
                return AnisetteData(
                    clientTime: clientTime,
                    routingInfo: anisetteResponse.routingInfo,
                    machineID: anisetteResponse.machineID,
                    localUserID: anisetteResponse.localUserID,
                    oneTimePassword: anisetteResponse.oneTimePassword
                )
            })
        }
    }

}
