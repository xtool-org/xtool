import Foundation
import Dependencies

/// Apple-facing client identity used by the remote Anisette provider.
/// The selection is independent of the saved ADI provisioning state.
public enum GrandSlamMacProfile: String, CaseIterable, Sendable {
    case provider
    case modern

    public static let storageKey = "XTLGSAMacProfile"
    public static let environmentVariable = "XTL_GSA_MAC_PROFILE"
}

struct OmnisetteADIProvider: RawADIProvider {
    @Dependency(\.httpClient) private var client
    @Dependency(\.keyValueStorage) private var storage

    // should implement v3 of https://github.com/SideStore/omnisette-server
    // list: https://servers.sidestore.io/servers.json
    private let url: URL
    init(
        url: URL = URL(string: "https://mac-ani.jkcoxson.com")!
    ) {
        self.url = url
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dataDecodingStrategy = .base64
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dataEncodingStrategy = .base64
        return encoder
    }()

    // A modern macOS 27 / MacBook Air M5 identity using Apple's akd client.
    // The akd identity avoids HTTP 503 responses to legacy Xcode client-info.
    // The remote Mac Anisette server still supplies the provisioning and OTP data.
    // Keep this opt-in: spoofing a different identity may be rejected by Apple.
    static let modernMacClientInfo = """
        <Mac17,3> <macOS;27.0;26A5416b> <com.apple.AuthKit/1 (com.apple.akd/1.0)>
        """

    enum ClientInfoProfileError: Error, LocalizedError {
        case invalidProfile(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let name):
                return "Unknown XTL_GSA_MAC_PROFILE '\(name)'; use 'provider' or 'modern'."
            }
        }
    }

    static func resolvedClientInfo(_ serverClientInfo: String, profile: String?) throws -> String {
        switch profile {
        case nil, "", "provider":
            return serverClientInfo
        case "modern":
            return modernMacClientInfo
        case .some(let name):
            throw ClientInfoProfileError.invalidProfile(name)
        }
    }

    static func selectedProfileName(environment: String?, stored: String?) -> String? {
        if let environment, !environment.isEmpty {
            return environment
        }
        return stored
    }

    func clientInfo() async throws -> String {
        struct ClientInfo: Decodable {
            let clientInfo: String
        }
        let body = try await client.makeRequest(
            HTTPRequest(url: url.appendingPathComponent("v3/client_info"))
        ).body
        let serverClientInfo = try Self.decoder.decode(ClientInfo.self, from: body).clientInfo
        let profile = Self.selectedProfileName(
            environment: ProcessInfo.processInfo.environment[GrandSlamMacProfile.environmentVariable],
            stored: try storage.string(forKey: GrandSlamMacProfile.storageKey)
        )
        let clientInfo = try Self.resolvedClientInfo(serverClientInfo, profile: profile)
        if profile == GrandSlamMacProfile.modern.rawValue {
            print("Experimental Apple device profile: Mac17,3 / macOS 27.0 (akd client).")
        }
        return clientInfo
    }

    func startProvisioning(spim: Data, userID: UUID) async throws -> (RawADIProvisioningSession, Data) {
        var url = url.appendingPathComponent("v3/provisioning_session")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        url = components.url!

        let task = try await client.makeWebSocket(url: url)
        let connection = OmnisetteProvisioningSession(task: task)
        let cpim = try await connection.startProvisioning(spim: spim, userID: userID)
        return (connection, cpim)
    }

    func requestOTP(
        userID: UUID,
        routingInfo: inout UInt64,
        provisioningInfo: Data
    ) async throws -> (machineID: Data, otp: Data) {
        struct Request: Encodable {
            let identifier: Data
            let adiPb: Data
        }

        struct Response: Decodable {
            var machineID: Data
            var otp: Data
            var rinfo: String

            private enum CodingKeys: String, CodingKey {
                case machineID = "X-Apple-I-MD-M"
                case otp = "X-Apple-I-MD"
                case rinfo = "X-Apple-I-MD-RINFO"
            }
        }

        var request = HTTPRequest(url: url.appendingPathComponent("v3/get_headers"))
        request.method = .post
        request.headerFields[.contentType] = "application/json"
        let body = try Self.encoder.encode(Request(
            identifier: userID.rawBytes,
            adiPb: provisioningInfo
        ))
        let response = try await client.makeRequest(request, body: body).body
        let decoded = try Self.decoder.decode(Response.self, from: response)
        if let rinfo = UInt64(decoded.rinfo) {
            routingInfo = rinfo
        }
        return (decoded.machineID, decoded.otp)
    }
}

private final class OmnisetteProvisioningSession: RawADIProvisioningSession {
    let task: WebSocketSession

    init(task: WebSocketSession) {
        self.task = task
    }

    deinit {
        close()
    }

    private func close() {
        task.close()
    }

    func startProvisioning(
        spim: Data,
        userID: UUID
    ) async throws -> Data {
        do {
            struct Response: Encodable {
                let identifier: Data
            }
            try await receive("GiveIdentifier")
            try await send(Response(identifier: userID.rawBytes))
        }

        do {
            struct Response: Encodable {
                let spim: Data
            }
            try await receive("GiveStartProvisioningData")
            try await send(Response(spim: spim))
        }

        do {
            struct Request: Decodable {
                let cpim: Data
            }
            return try await receive("GiveEndProvisioningData", as: Request.self).cpim
        }
    }

    func endProvisioning(routingInfo: UInt64, ptm: Data, tk: Data) async throws -> Data {
        defer { close() }
        do {
            struct Response: Encodable {
                let ptm: Data
                let tk: Data
            }
            try await send(Response(ptm: ptm, tk: tk))
        }

        do {
            struct Request: Decodable {
                let adiPb: Data
            }
            return try await receive("ProvisioningSuccess", as: Request.self).adiPb
        }
    }

    private struct Header: Decodable {
        let result: String
    }

    @discardableResult
    private func receive<T: Decodable>(_ message: String, as type: T.Type = EmptyResponse.self) async throws -> T {
        let data = switch try await task.receive() {
        case .data(let data): data
        case .text(let text): Data(text.utf8)
        @unknown default: Data()
        }
        let header = try OmnisetteADIProvider.decoder.decode(Header.self, from: data)
        guard header.result == message else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Expected message '\(message)', got \(header.result)"
            ))
        }
        return try OmnisetteADIProvider.decoder.decode(type, from: data)
    }

    private func send<T: Encodable>(_ message: T) async throws {
        let encoded = try OmnisetteADIProvider.encoder.encode(message)
        try await task.send(.text(String(decoding: encoded, as: UTF8.self)))
    }
}

extension UUID {
    fileprivate var rawBytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}
