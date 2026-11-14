import Foundation
import ConcurrencyExtras
import Dependencies
import XUtils

public protocol RawADIProvider: Sendable {
    var providerID: String { get }

    /// Whether anisette is generated on this machine rather than by a remote service.
    var isLocal: Bool { get }

    func localUserID(for userID: UUID) -> String

    func clientInfo() async throws -> ClientInfoWithUserAgent

    func startProvisioning(
        spim: Data,
        userID: UUID
    ) async throws -> (RawADIProvisioningSession, Data)

    func requestOTP(
        userID: UUID,
        routingInfo: inout UInt64,
        provisioningInfo: inout Data
    ) async throws -> (machineID: Data, otp: Data)
}

public struct ClientInfoWithUserAgent: Sendable {
    public let clientInfo: String
    public let akdUserAgent: String
}

private struct UnimplementedRawADIProvider: RawADIProvider {
    let providerID = "unimplemented"
    let isLocal = false

    func localUserID(for userID: UUID) -> String {
        let closure: (UUID) -> String = unimplemented(placeholder: "")
        return closure(userID)
    }

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
        provisioningInfo: inout Data
    ) async throws -> (machineID: Data, otp: Data) {
        let closure: (UUID, inout UInt64, inout Data) async throws -> (Data, Data) = unimplemented()
        return try await closure(userID, &routingInfo, &provisioningInfo)
    }

    func clientInfo() async throws -> ClientInfoWithUserAgent {
        let closure: () async throws -> ClientInfoWithUserAgent = unimplemented()
        return try await closure()
    }
}

enum RawADIProviderDependencyKey: DependencyKey {
    static let testValue: RawADIProvider = UnimplementedRawADIProvider()
    static let liveValue: RawADIProvider = provider(named: ProcessInfo.processInfo.environment["XTL_ANISETTE_PROVIDER"])

    /// `XTL_ANISETTE_PROVIDER` selects `local` (Anisette, macOS/Linux only) or `omnisette`.
    /// The remote provider is a fallback for when local ADI's pinned Apple or Unicorn
    /// downloads become unavailable.
    static func provider(named name: String?) -> RawADIProvider {
        switch name {
        case nil, "": break
        case "omnisette": return OmnisetteADIProvider()
        #if os(macOS) || os(Linux)
        case "local": return AnisetteProvider()
        #endif
        case let name?:
            stderrPrint("warning: Ignoring unsupported XTL_ANISETTE_PROVIDER value '\(name)'.")
        }
        #if os(macOS) || os(Linux)
        return AnisetteProvider()
        #else
        return OmnisetteADIProvider()
        #endif
    }
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

private actor ADIStateGate {
    static let shared = ADIStateGate()

    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if occupied {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            occupied = true
        }
        defer {
            if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await operation()
    }
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

    private let _clientInfo = LockIsolated<ClientInfoWithUserAgent?>(nil)

    public init() {
        @Dependency(\.keyValueStorage) var storage
        @Dependency(\.rawADIProvider) var rawProvider

        if let localUserUIDString = try? storage.string(forKey: Self.localUserUIDKey),
           let localUserUID = UUID(uuidString: localUserUIDString) {
            self.localUserUID = localUserUID
        } else {
            let localUserUID = UUID()
            try? storage.setString(localUserUID.uuidString, forKey: Self.localUserUIDKey)
            self.localUserUID = localUserUID
        }
        self.localUserID = rawProvider.localUserID(for: localUserUID)
    }

    private static var stateLockURL: URL {
        XToolCache.directory.appendingPathComponent("anisette-state.lock")
    }

    /// Serializes the read → generate → persist transaction on the stored ADI state.
    private func withStateLock<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await ADIStateGate.shared.run {
            // Local ADI advances the stored state as it issues OTPs, so other xtool
            // processes have to be kept out too. Remote state never changes.
            guard rawProvider.isLocal else { return try await operation() }
            return try await withFileLock(at: Self.stateLockURL, operation)
        }
    }

    private static let localUserUIDKey = "XTLLocalUserUID"
    private static let providerIDKey = "XTLADIProviderID"
    private static let provisioningKey = "XTLProvisioningInfo"
    private static let routingInfoKey = "XTLRoutingInfo"

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

    private func clientInfo() async throws -> ClientInfoWithUserAgent {
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
            .accept: "*/*",
            .userAgent: try await clientInfo().akdUserAgent,
            .contentType: "text/x-xml-plist",
            .acceptLanguage: "en_US",
            .init(AnisetteData.localUserIDKey)!: self.localUserID,
        ]
        request.headerFields[.init("X-MMe-Country")!] = Locale.current.region?.identifier

        for (key, value) in try await deviceInfo().dictionary {
            request.headerFields[.init(key)!] = value
        }

        let (_, response) = try await self.httpClient.makeRequest(request, body: body, ephemeral: true)

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
        let originalRoutingInfo = routingInfo
        let originalProvisioningInfo = provisioningInfo
        var routingInfo = routingInfo
        var provisioningInfo = provisioningInfo
        let (mid, otp) = try await rawProvider.requestOTP(
            userID: localUserUID,
            routingInfo: &routingInfo,
            provisioningInfo: &provisioningInfo
        )
        if provisioningInfo != originalProvisioningInfo {
            try storage.setData(provisioningInfo, forKey: Self.provisioningKey)
        }
        if routingInfo != originalRoutingInfo {
            try storage.setString("\(routingInfo)", forKey: Self.routingInfoKey)
        }
        return AnisetteData(
            clientTime: Date(),
            routingInfo: routingInfo,
            machineID: mid.base64EncodedString(),
            localUserID: self.localUserID,
            oneTimePassword: otp.base64EncodedString(),
            deviceInfo: try await deviceInfo(),
        )
    }

    private func clearProvisioning() {
        try? storage.setData(nil, forKey: Self.provisioningKey)
        try? storage.setString(nil, forKey: Self.routingInfoKey)
    }

    public func resetProvisioning() async {
        try? await withStateLock { clearProvisioning() }
    }

    public var providerID: String? { rawProvider.providerID }

    public func provisioningData() -> ProvisioningData? {
        guard (try? storage.string(forKey: Self.providerIDKey)) == rawProvider.providerID,
              let provisioningInfo = try? storage.data(forKey: Self.provisioningKey),
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
        try await withStateLock { try await fetchLockedAnisetteData() }
    }

    private func fetchLockedAnisetteData() async throws -> AnisetteData {
        if (try? storage.string(forKey: Self.providerIDKey)) != rawProvider.providerID {
            clearProvisioning()
            try storage.setString(rawProvider.providerID, forKey: Self.providerIDKey)
        }
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

    public func deviceInfo() async throws -> DeviceInfo {
        let clientInfo = try await clientInfo()
        return DeviceInfo(
            deviceID: localUserUID.uuidString,
            clientInfo: clientInfo.clientInfo,
            akdUserAgent: clientInfo.akdUserAgent,
        )
    }

}

public struct ADIError: Error, CustomStringConvertible {
    public var code: Int

    public var description: String {
        switch code {
        case -45061:
            return """
            You were logged out. Please log in again with `xtool auth`.

            If you see this repeatedly, please file an issue at https://github.com/xtool-org/xtool/issues/new/choose
            """
        default:
            return """
            Apple Anisette library returned error \(code). Please try logging in again with `xtool auth`.

            If this problem persists, file an issue at https://github.com/xtool-org/xtool/issues/new/choose
            """
        }
    }
}
