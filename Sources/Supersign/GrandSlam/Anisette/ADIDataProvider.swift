import Foundation
import Crypto
import ConcurrencyExtras
import Dependencies

public protocol RawADIProvider: Sendable {
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

private struct UnimplementedRawADIProvider: RawADIProvider {
    func startProvisioning(
        spim: Data,
        userID: UUID
    ) async throws -> (any RawADIProvisioningSession, Data) {
        let closure: (Data, UUID) async throws -> (any RawADIProvisioningSession, Data) = unimplemented()
        return try await closure(spim, userID)
    }

    func requestOTP(
        userID: UUID,
        routingInfo: inout UInt64,
        provisioningInfo: Data
    ) async throws -> (machineID: Data, otp: Data) {
        let closure: (UUID, inout UInt64, Data) async throws -> (Data, Data) = unimplemented()
        return try await closure(userID, &routingInfo, provisioningInfo)
    }
}

public enum RawADIProviderDependencyKey: DependencyKey {
    public static let testValue: RawADIProvider = UnimplementedRawADIProvider()
    public static let liveValue: RawADIProvider = {
        #if os(Linux)
        return SupersetteADIProvider()
        #else
        return OmnisetteADIProvider()
        #endif
    }()
}

extension DependencyValues {
    public var rawADIProvider: RawADIProvider {
        get { self[RawADIProviderDependencyKey.self] }
        set { self[RawADIProviderDependencyKey.self] = newValue }
    }
}

public protocol RawADIProvisioningSession: Sendable {
    func endProvisioning(
        routingInfo: UInt64,
        ptm: Data,
        tk: Data
    ) async throws -> Data
}

// uses CoreADI APIs
public struct ADIDataProvider: AnisetteDataProvider {

    public enum ADIError: Error {
        case hashingFailed
        case noResponse
        case badStartResponse
        case badEndResponse
    }

    @Dependency(\.keyValueStorage) var storage
    @Dependency(\.rawADIProvider) var rawProvider
    @Dependency(\.httpClient) var httpClient

    private let lookupManager = GrandSlamLookupManager()
    private let localUserUID: UUID
    private let localUserID: String

    private let _clientInfo = LockIsolated<String?>(nil)

    public init(provisioningData: ProvisioningData? = nil) {
        @Dependency(\.keyValueStorage) var storage
        if let provisioningData {
            self.localUserUID = provisioningData.localUserUID
            try? storage.setData(provisioningData.adiPb, forKey: Self.provisioningKey)
            try? storage.setString("\(provisioningData.routingInfo)", forKey: Self.routingInfoKey)
        } else if let localUserUIDString = try? storage.string(forKey: Self.localUserUIDKey),
           let localUserUID = UUID(uuidString: localUserUIDString) {
            self.localUserUID = localUserUID
        } else {
            let localUserUID = UUID()
            try? storage.setString(localUserUID.uuidString, forKey: Self.localUserUIDKey)
            self.localUserUID = localUserUID
        }
        // localUserID = SHA256(local user UID)
        self.localUserID = SHA256.hash(data: Data(localUserUID.uuidString.utf8))
            .map { String(format: "%02X", $0) }
            .joined()
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
        if let clientInfo = _clientInfo.value { return clientInfo }
        let clientInfo = try await rawProvider.clientInfo()
        _clientInfo.setValue(clientInfo)
        return clientInfo
    }

    private func sendRequest<Request: Encodable, Response: Decodable>(
        endpoint: GrandSlamEndpoint,
        request: Request
    ) async throws -> Response {
        let endpointURL = try await lookupManager.fetchURL(forEndpoint: endpoint)

        let body = try Self.encoder.encode(GSARequest(request: request))

        var request = HTTPRequest(url: endpointURL)
        request.method = .post
        request.headerFields = [
            .contentType: "text/x-xml-plist",
            .acceptLanguage: "en_US",
            .init(AnisetteData.localUserIDKey)!: self.localUserID,
        ]
        request.headerFields[.init("X-MMe-Country")!] = Locale.current.regionCode

        request.headerFields[.init(DeviceInfo.clientInfoKey)!] = try await clientInfo()
        request.headerFields[.init(DeviceInfo.deviceIDKey)!] = self.localUserUID.uuidString
//        request.headers[DeviceInfo.clientInfoKey] = self.deviceInfo.clientInfo.clientString
//        self.deviceInfo.dictionary.forEach { request.headers[$0] = $1 }

        let (_, response) = try await self.httpClient.makeRequest(request, body: body)

//        print(String(data: response, encoding: .utf8) ?? "<no utf8 data>")

        return try GrandSlamOperationDecoder<Response>.decode(data: response)
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

    public func resetProvisioning() {
        try? storage.setData(nil, forKey: Self.provisioningKey)
        try? storage.setString(nil, forKey: Self.routingInfoKey)
    }

    public func provisioningData() -> ProvisioningData? {
        guard let provisioningInfo = try? storage.data(forKey: Self.provisioningKey),
              let routingInfoString = try? storage.string(forKey: Self.routingInfoKey),
              let routingInfo = UInt64(routingInfoString)
        else { return nil }
        return ProvisioningData(
            localUserUID: localUserUID,
            routingInfo: routingInfo,
            adiPb: provisioningInfo
        )
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

public struct ADIError: Error {
    public var code: Int
}
