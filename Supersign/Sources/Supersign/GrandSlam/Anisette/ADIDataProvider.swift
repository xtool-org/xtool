import Foundation
import Crypto

enum HashingError: Error {
    case hashingFailed
}

private extension Data {
    func sha256() throws -> [UInt8] {
        Array(SHA256.hash(data: self))
    }
}

public protocol RawADIProvider {
    func clientInfo() async throws -> String

    func startProvisioning(
        spim: Data,
        userID: UUID
    ) async throws -> (RawADIProvisioningSession, Data)

    func requestOTP(
        userID: UUID,
        routingInfo: inout UInt64,
        provisioningInfo: Data
    ) async throws -> (machineID: Data, otp: Data)
}

extension RawADIProvider {
    public func clientInfo() async throws -> String {
        // Looks like Apple detects attempts to use a macOS client string on Windows :/
        """
        <PC> <Windows;6.2(0,0);9200> <com.apple.AuthKitWin/1 (com.apple.iCloud/7.21)>
        """
    }
}

public protocol RawADIProvisioningSession {
    func endProvisioning(
        routingInfo: UInt64,
        ptm: Data,
        tk: Data
    ) async throws -> Data
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
    private let localUserUID: UUID
    private let localUserID: String

    private var _clientInfo: String?

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

        if let localUserUIDString = try storage.string(forKey: Self.localUserUIDKey),
           let localUserUID = UUID(uuidString: localUserUIDString) {
            self.localUserUID = localUserUID
        } else {
            let localUserUID = UUID()
            try storage.setString(localUserUID.uuidString, forKey: Self.localUserUIDKey)
            self.localUserUID = localUserUID
        }
        // localUserID = SHA256(local user UID)
        self.localUserID = try Data(localUserUID.uuidString.utf8).sha256().map { String(format: "%02X", $0) }.joined()
    }

    private static let localUserUIDKey = "SUPLocalUserUID"
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

    private func clientInfo() async throws -> String {
        if let _clientInfo { return _clientInfo }
        let clientInfo = try await rawProvider.clientInfo()
        self._clientInfo = clientInfo
        return clientInfo
    }

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

        request.headers[DeviceInfo.clientInfoKey] = try await clientInfo()
        request.headers[DeviceInfo.deviceIDKey] = self.localUserUID.uuidString
//        request.headers[DeviceInfo.clientInfoKey] = self.deviceInfo.clientInfo.clientString
//        self.deviceInfo.dictionary.forEach { request.headers[$0] = $1 }

        let resp = try await self.httpClient.makeRequest(request)

        guard let body = resp.body else { throw ADIError.noResponse }
//        print(String(data: body, encoding: .utf8) ?? "<no utf8 data>")

        return try GrandSlamOperationDecoder<Response>.decode(data: body)
    }

    private func endProvisioning(
        session: RawADIProvisioningSession,
        cpim: Data
    ) async throws -> (routingInfo: UInt64, provisioningInfo: Data) {
        let resp: EndProvisioningResponse = try await sendRequest(
            endpoint: .lookup(\.midFinishProvisioning),
            request: EndProvisioningRequest(cpim: cpim.base64EncodedString())
        )

        guard let rinfo = UInt64(resp.rinfo),
              let ptm = Data(base64Encoded: resp.ptm),
              let tk = Data(base64Encoded: resp.tk)
            else { throw ADIError.badEndResponse }

        let provisioningInfo = try await session.endProvisioning(
            routingInfo: rinfo, ptm: ptm, tk: tk
        )

        return (rinfo, provisioningInfo)
    }

    private func provision() async throws -> (routingInfo: UInt64, provisioningInfo: Data) {
        let resp: StartProvisioningResponse = try await sendRequest(
            endpoint: .lookup(\.midStartProvisioning),
            request: StartProvisioningRequest()
        )
        guard let spim = Data(base64Encoded: resp.spim) else { throw ADIError.badStartResponse }
        let (session, cpim) = try await rawProvider.startProvisioning(spim: spim, userID: localUserUID)
        return try await endProvisioning(session: session, cpim: cpim)
    }

    private func fetchAnisetteData(
        routingInfo: UInt64,
        provisioningInfo: Data
    ) async throws -> AnisetteData {
        let requestTime = Date()
        var routingInfo = routingInfo
        let (mid, otp) = try await rawProvider.requestOTP(userID: localUserUID, routingInfo: &routingInfo, provisioningInfo: provisioningInfo)
        return AnisetteData(
            clientTime: requestTime,
            routingInfo: routingInfo,
            machineID: mid.base64EncodedString(),
            localUserID: self.localUserID,
            oneTimePassword: otp.base64EncodedString(),
            deviceID: self.localUserUID.uuidString
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
