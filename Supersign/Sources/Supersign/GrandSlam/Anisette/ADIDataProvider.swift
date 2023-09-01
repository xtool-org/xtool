import Foundation
import Crypto

enum HashingError: Error {
    case hashingFailed
}

private extension String {
    func sha256() throws -> [UInt8] {
        Array(SHA256.hash(data: Data(utf8)))
    }
}

public protocol RawADIProvider {
    func startProvisioning(spim: Data) async throws -> (String, Data)

    func endProvisioning(
        session: String,
        routingInfo: UInt64,
        ptm: Data,
        tk: Data
    ) async throws -> Data

    func requestOTP(provisioningInfo: Data) async throws -> (machineID: Data, otp: Data)
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
        request: Request
    ) async throws -> Response {
        let endpointURL = try await lookupManager.fetchURL(forEndpoint: endpoint)

        let body = try Self.encoder.encode(GSARequest(request: request))

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
//        request.headers[DeviceInfo.clientInfoKey] = self.deviceInfo.clientInfo.clientString
//        self.deviceInfo.dictionary.forEach { request.headers[$0] = $1 }

        let resp = try await self.httpClient.makeRequest(request)

        guard let body = resp.body else { throw ADIError.noResponse }
//        print(String(data: body, encoding: .utf8) ?? "<no utf8 data>")

        return try GrandSlamOperationDecoder<Response>.decode(data: body)
    }

    private func endProvisioning(
        id: String,
        cpim: Data
    ) async throws -> (routingInfo: UInt64, provisioningInfo: Data) {
        let resp: EndProvisioningResponse = try await sendRequest(
            endpoint: \.midFinishProvisioning,
            request: EndProvisioningRequest(cpim: cpim.base64EncodedString())
        )

        guard let rinfo = UInt64(resp.rinfo),
              let ptm = Data(base64Encoded: resp.ptm),
              let tk = Data(base64Encoded: resp.tk)
            else { throw ADIError.badEndResponse }

        let provisioningInfo = try await self.rawProvider.endProvisioning(
            session: id, routingInfo: rinfo, ptm: ptm, tk: tk
        )

        return (rinfo, provisioningInfo)
    }

    private func provision() async throws -> (routingInfo: UInt64, provisioningInfo: Data) {
        let resp: StartProvisioningResponse = try await sendRequest(
            endpoint: \.midStartProvisioning,
            request: StartProvisioningRequest()
        )
        guard let spim = Data(base64Encoded: resp.spim) else { throw ADIError.badStartResponse }
        let (id, cpim) = try await rawProvider.startProvisioning(spim: spim)
        return try await endProvisioning(id: id, cpim: cpim)
    }

    private func fetchAnisetteData(
        routingInfo: UInt64,
        provisioningInfo: Data
    ) async throws -> AnisetteData {
        let requestTime = Date()
        let (mid, otp) = try await rawProvider.requestOTP(provisioningInfo: provisioningInfo)
        return AnisetteData(
            clientTime: requestTime,
            routingInfo: routingInfo,
            machineID: mid.base64EncodedString(),
            localUserID: self.localUserID,
            oneTimePassword: otp.base64EncodedString()
        )
    }

    public func resetProvisioning() throws {
        try storage.setData(nil, forKey: Self.provisioningKey)
        try storage.setString(nil, forKey: Self.routingInfoKey)
    }

    public func fetchAnisetteData() async throws -> AnisetteData {
        if let provisioningInfo = try storage.data(forKey: Self.provisioningKey),
                  let routingInfoString = try storage.string(forKey: Self.routingInfoKey),
                  let routingInfo = UInt64(routingInfoString) {
            return try await fetchAnisetteData(
                routingInfo: routingInfo,
                provisioningInfo: provisioningInfo
            )
        }

        let (rinfo, data) = try await provision()

        try self.storage.setData(data, forKey: Self.provisioningKey)
        try self.storage.setString("\(rinfo)", forKey: Self.routingInfoKey)

        return try await fetchAnisetteData(
            routingInfo: rinfo,
            provisioningInfo: data
        )
    }

}
