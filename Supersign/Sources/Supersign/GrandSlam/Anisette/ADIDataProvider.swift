import Foundation
import CryptoKit

enum HashingError: Error {
    case hashingFailed
}

private extension String {
    func sha256() throws -> SHA256Digest {
        SHA256.hash(data: Data(utf8))
    }
}

public protocol RawADIProvider {
    func startProvisioning(
        spim: Data,
        completion: @escaping (Result<(String, Data), Error>) -> Void
    )

    func endProvisioning(
        session: String,
        routingInfo: UInt64,
        ptm: Data,
        tk: Data,
        completion: @escaping (Result<Data, Error>) -> Void
    )

    func requestOTP(
        provisioningInfo: Data,
        completion: @escaping (Result<(machineID: Data, otp: Data), Error>) -> Void
    )
}

// uses CoreADI APIs
public final class ADIDataProvider: AnisetteDataProvider {

    public enum ADIError: Error {
        case hashingFailed
        case noResponse
        case badStartResponse
        case badEndResponse
    }

    public let rawProvider: RawADIProvider
    public let deviceInfo: DeviceInfo
    public let storage: KeyValueStorage

    private let httpClient: HTTPClientProtocol
    private let lookupManager: GrandSlamLookupManager
    private let localUserID: String

    public init(
        rawProvider: RawADIProvider,
        deviceInfo: DeviceInfo,
        storage: KeyValueStorage, // ideally secure, eg keychain
        httpFactory: HTTPClientFactory = defaultHTTPClientFactory
    ) throws {
        self.rawProvider = rawProvider
        self.deviceInfo = deviceInfo
        self.storage = storage

        self.httpClient = httpFactory.makeClient()
        self.lookupManager = .init(deviceInfo: deviceInfo, httpFactory: httpFactory)

        if let localUserID = try storage.string(forKey: Self.localUserIDKey) {
            self.localUserID = localUserID
        } else {
            // localUserID = SHA256(local user UID)
            let localUserUID = UUID().uuidString
            let localUserID = try localUserUID.sha256().map { String(format: "%02X", $0) }.joined()
            try storage.setString(localUserID, forKey: Self.localUserIDKey)
            self.localUserID = localUserID
        }
    }

    private static let localUserIDKey = "SUPLocalUserID"
    private static let provisioningKey = "SUPProvisioningInfo"
    private static let routingInfoKey = "SUPRoutingInfo"

    private struct GSARequest<T: Encodable>: Encodable {
        let header: [String: String] = [:]
        let request: T

        private enum CodingKeys: String, CodingKey {
            case header = "Header"
            case request = "Request"
        }
    }

    private struct StartProvisioningRequest: Encodable {}
    private struct StartProvisioningResponse: Decodable {
        let spim: String
    }

    private struct EndProvisioningRequest: Encodable {
        let cpim: String
    }
    private struct EndProvisioningResponse: Decodable {
        let ptm: String // base64
        let tk: String // base64
        let rinfo: String // number (u64)

        private enum CodingKeys: String, CodingKey {
            case ptm
            case tk
            case rinfo = "X-Apple-I-MD-RINFO"
        }
    }

    private static let encoder: PropertyListEncoder = {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return encoder
    }()

    private func sendRequest<Request: Encodable, Response: Decodable>(
        endpoint: GrandSlamEndpoint,
        request: Request,
        completion: @escaping (Result<Response, Error>) -> Void
    ) {
        lookupManager.fetchURL(forEndpoint: endpoint) { result in
            guard let endpointURL = result.get(withErrorHandler: completion) else { return }
            let body: Data
            do {
                body = try Self.encoder.encode(GSARequest(request: request))
            } catch {
                return completion(.failure(error))
            }
            var request = HTTPRequest(
                url: endpointURL,
                method: "POST",
                headers: [
                    "Content-Type": "text/x-xml-plist",
                    AnisetteData.localUserIDKey: self.localUserID,
                    "Accept-Language": "en_US"
                ],
                body: .buffer(body)
            )
            request.headers["X-MMe-Country"] = Locale.current.regionCode

            // Looks like Apple detects attempts to use a macOS client string on Windows :/
            request.headers[DeviceInfo.clientInfoKey] = """
            <PC> <Windows;6.2(0,0);9200> <com.apple.AuthKitWin/1 (com.apple.iCloud/7.21)>
            """
            request.headers[DeviceInfo.deviceIDKey] = self.deviceInfo.deviceID
//            request.headers[DeviceInfo.clientInfoKey] = self.deviceInfo.clientInfo.clientString
//            self.deviceInfo.dictionary.forEach { request.headers[$0] = $1 }

            self.httpClient.makeRequest(request) { result in
                guard let resp = result.get(withErrorHandler: completion) else { return }
                guard let body = resp.body else { return completion(.failure(ADIError.noResponse)) }
//                print(String(data: body, encoding: .utf8) ?? "<no utf8 data>")
                completion(Result {
                    try GrandSlamOperationDecoder<Response>.decode(data: body)
                })
            }
        }
    }

    private func endProvisioning(
        id: String,
        cpim: Data,
        completion: @escaping (Result<(routingInfo: UInt64, provisioningInfo: Data), Error>) -> Void
    ) {
        sendRequest(
            endpoint: \.midFinishProvisioning,
            request: EndProvisioningRequest(cpim: cpim.base64EncodedString())
        ) { (result: Result<EndProvisioningResponse, Error>) -> Void in
            guard let resp = result.get(withErrorHandler: completion) else { return }
            guard let rinfo = UInt64(resp.rinfo),
                  let ptm = Data(base64Encoded: resp.ptm),
                  let tk = Data(base64Encoded: resp.tk)
            else { return completion(.failure(ADIError.badEndResponse)) }
            self.rawProvider.endProvisioning(session: id, routingInfo: rinfo, ptm: ptm, tk: tk) { result in
                guard let provisioningInfo = result.get(withErrorHandler: completion) else { return }
                completion(.success((rinfo, provisioningInfo)))
            }
        }
    }

    private func provision(completion: @escaping (Result<(routingInfo: UInt64, provisioningInfo: Data), Error>) -> Void) {
        sendRequest(
            endpoint: \.midStartProvisioning,
            request: StartProvisioningRequest()
        ) { (result: Result<StartProvisioningResponse, Error>) -> Void in
            guard let resp = result.get(withErrorHandler: completion) else { return }
            guard let spim = Data(base64Encoded: resp.spim) else {
                return completion(.failure(ADIError.badStartResponse))
            }
            self.rawProvider.startProvisioning(spim: spim) { result in
                guard let (id, cpim) = result.get(withErrorHandler: completion) else { return }
                self.endProvisioning(id: id, cpim: cpim, completion: completion)
            }
        }
    }

    private func fetchAnisetteData(
        routingInfo: UInt64,
        provisioningInfo: Data,
        completion: @escaping (Result<AnisetteData, Error>) -> Void
    ) {
        let requestTime = Date()
        rawProvider.requestOTP(provisioningInfo: provisioningInfo) { result in
            guard let (mid, otp) = result.get(withErrorHandler: completion) else { return }
            completion(.success(AnisetteData(
                clientTime: requestTime,
                routingInfo: routingInfo,
                machineID: mid.base64EncodedString(),
                localUserID: self.localUserID,
                oneTimePassword: otp.base64EncodedString()
            )))
        }
    }

    public func resetProvisioning(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(Result {
            try storage.setData(nil, forKey: Self.provisioningKey)
            try storage.setString(nil, forKey: Self.routingInfoKey)
        })
    }

    public func fetchAnisetteData(completion: @escaping (Result<AnisetteData, Error>) -> Void) {
        do {
            if let provisioningInfo = try storage.data(forKey: Self.provisioningKey),
                      let routingInfoString = try storage.string(forKey: Self.routingInfoKey),
                      let routingInfo = UInt64(routingInfoString) {
                return fetchAnisetteData(
                    routingInfo: routingInfo,
                    provisioningInfo: provisioningInfo,
                    completion: completion
                )
            }
        } catch {
            return completion(.failure(error))
        }
        provision { result in
            guard let (rinfo, data) = result.get(withErrorHandler: completion) else { return }
            do {
                try self.storage.setData(data, forKey: Self.provisioningKey)
                try self.storage.setString("\(rinfo)", forKey: Self.routingInfoKey)
            } catch {
                return completion(.failure(error))
            }
            self.fetchAnisetteData(
                routingInfo: rinfo,
                provisioningInfo: data,
                completion: completion
            )
        }
    }

}
