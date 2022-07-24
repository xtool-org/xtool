import Foundation

public class SupersetteADIProvider: RawADIProvider {
    private static let gateway = "http://kabir-winvm.local:3000/v1"

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public enum Error: Swift.Error {
        case networkError
        case invalidResponse
    }

    public let deviceInfo: DeviceInfo
    private let httpClient: HTTPClientProtocol

    public init(deviceInfo: DeviceInfo, httpFactory: HTTPClientFactory = defaultHTTPClientFactory) {
        self.deviceInfo = deviceInfo
        self.httpClient = httpFactory.makeClient()
    }

    private func makeRequest<Request: Encodable, Response: Decodable>(
        endpoint: StaticString,
        request: Request,
        completion: @escaping (Result<Response, Swift.Error>) -> Void
    ) {
        let url = URL(string: "\(Self.gateway)/\(endpoint)")!
        var httpRequest = HTTPRequest(url: url, method: "POST")
        httpRequest.headers = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Superkey": "BF95B548-3C87-4BBD-8B96-534421368416"
        ]
        do {
            httpRequest.body = try .buffer(Self.encoder.encode(request))
        } catch {
            return completion(.failure(error))
        }
//        print("Requesting \(endpoint):")
//        dump(request)
        httpClient.makeRequest(httpRequest) { result in
            let result = Result { () throws -> Response in
                let resp = try result.get()
                let data = try resp.body.orThrow(Error.invalidResponse)
                return try Self.decoder.decode(Response.self, from: data)
            }
//            print("Response for \(endpoint):")
//            dump(result)
            completion(result)
        }
    }

    public func startProvisioning(
        spim: Data,
        completion: @escaping (Result<(String, Data), Swift.Error>) -> Void
    ) {
        struct Request: Encodable {
            let spim: Data
        }
        struct Response: Decodable {
            let sessionID: String
            let cpim: Data
        }
        makeRequest(
            endpoint: "start-provisioning",
            request: Request(spim: spim)
        ) { (res: Result<Response, Swift.Error>) -> Void in
            completion(res.map { ($0.sessionID, $0.cpim) })
        }
    }

    public func endProvisioning(
        session: String,
        routingInfo: UInt64,
        ptm: Data,
        tk: Data,
        completion: @escaping (Result<Data, Swift.Error>) -> Void
    ) {
        struct Request: Encodable {
            let session: String
            let rinfo: String
            let ptm: Data
            let tk: Data
        }
        struct Response: Decodable {
            let provisioningInfo: Data
        }
        makeRequest(
            endpoint: "end-provisioning",
            request: Request(session: session, rinfo: "\(routingInfo)", ptm: ptm, tk: tk)
        ) { (res: Result<Response, Swift.Error>) -> Void in
            completion(res.map { $0.provisioningInfo })
        }
    }

    public func requestOTP(
        provisioningInfo: Data,
        completion: @escaping (Result<(machineID: Data, otp: Data), Swift.Error>) -> Void
    ) {
        struct Request: Encodable {
            let provisioningInfo: Data
        }
        struct Response: Decodable {
            let mid: Data
            let otp: Data
        }
        makeRequest(
            endpoint: "otp",
            request: Request(provisioningInfo: provisioningInfo)
        ) { (res: Result<Response, Swift.Error>) -> Void in
            completion(res.map { ($0.mid, $0.otp) })
        }
    }

}

extension ADIDataProvider {
    public static func supersetteProvider(
        deviceInfo: DeviceInfo,
        storage: KeyValueStorage,
        httpFactory: HTTPClientFactory = defaultHTTPClientFactory
    ) throws -> ADIDataProvider {
        return try ADIDataProvider(
            rawProvider: SupersetteADIProvider(deviceInfo: deviceInfo, httpFactory: httpFactory),
            deviceInfo: deviceInfo,
            storage: storage,
            httpFactory: httpFactory
        )
    }
}
