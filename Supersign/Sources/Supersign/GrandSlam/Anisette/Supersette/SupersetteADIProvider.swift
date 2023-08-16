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
        request: Request
    ) async throws -> Response {
        let url = URL(string: "\(Self.gateway)/\(endpoint)")!
        var httpRequest = HTTPRequest(url: url, method: "POST")
        httpRequest.headers = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Superkey": "BF95B548-3C87-4BBD-8B96-534421368416"
        ]
        httpRequest.body = try .buffer(Self.encoder.encode(request))
//        print("Requesting \(endpoint):")
//        dump(request)
        let resp = try await httpClient.makeRequest(httpRequest)
        let data = try resp.body.orThrow(Error.invalidResponse)
        return try Self.decoder.decode(Response.self, from: data)
    }

    public func startProvisioning(spim: Data) async throws -> (String, Data) {
        struct Request: Encodable {
            let spim: Data
        }
        struct Response: Decodable {
            let sessionID: String
            let cpim: Data
        }
        let resp: Response = try await makeRequest(
            endpoint: "start-provisioning",
            request: Request(spim: spim)
        )
        return (resp.sessionID, resp.cpim)
    }

    public func endProvisioning(
        session: String,
        routingInfo: UInt64,
        ptm: Data,
        tk: Data
    ) async throws -> Data {
        struct Request: Encodable {
            let session: String
            let rinfo: String
            let ptm: Data
            let tk: Data
        }
        struct Response: Decodable {
            let provisioningInfo: Data
        }
        let resp: Response = try await makeRequest(
            endpoint: "end-provisioning",
            request: Request(session: session, rinfo: "\(routingInfo)", ptm: ptm, tk: tk)
        )
        return resp.provisioningInfo
    }

    public func requestOTP(provisioningInfo: Data) async throws -> (machineID: Data, otp: Data) {
        struct Request: Encodable {
            let provisioningInfo: Data
        }
        struct Response: Decodable {
            let mid: Data
            let otp: Data
        }
        let resp: Response = try await makeRequest(
            endpoint: "otp",
            request: Request(provisioningInfo: provisioningInfo)
        )
        return (resp.mid, resp.otp)
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
