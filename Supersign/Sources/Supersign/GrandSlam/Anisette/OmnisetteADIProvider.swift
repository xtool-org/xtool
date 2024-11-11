import Foundation

struct OmnisetteADIProvider: RawADIProvider {
    // should implement v3 of https://github.com/SideStore/omnisette-server
    // list: https://servers.sidestore.io/servers.json
    // e.g. https://ani.sidestore.io
    private let url: URL
    init(url: URL = URL(string: "https://ani.sidestore.io")!) {
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

    func clientInfo() async throws -> String {
        struct ClientInfo: Decodable {
            let clientInfo: String
        }
        let (response, _) = try await URLSession.shared.data(from: url.appendingPathComponent("v3/client_info"))
        let clientInfo = try Self.decoder.decode(ClientInfo.self, from: response)
        return clientInfo.clientInfo
    }

    func startProvisioning(spim: Data, userID: UUID) async throws -> (RawADIProvisioningSession, Data) {
        var url = url.appendingPathComponent("v3/provisioning_session")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        url = components.url!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
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

        var request = URLRequest(url: url.appendingPathComponent("v3/get_headers"))
        request.httpMethod = "POST"
        request.httpBody = try Self.encoder.encode(Request(
            identifier: userID.rawBytes,
            adiPb: provisioningInfo
        ))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (response, _) = try await URLSession.shared.data(for: request)
        let decoded = try Self.decoder.decode(Response.self, from: response)
        if let rinfo = UInt64(decoded.rinfo) {
            routingInfo = rinfo
        }
        return (decoded.machineID, decoded.otp)
    }
}

private final class OmnisetteProvisioningSession: RawADIProvisioningSession {
    let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    deinit {
        close()
    }

    private func close() {
        task.cancel(with: .normalClosure, reason: nil)
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
        case .string(let text): Data(text.utf8)
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
        try await task.send(.string(String(decoding: encoded, as: UTF8.self)))
    }
}

extension UUID {
    var rawBytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}

extension ADIDataProvider {
    public static func omnisetteProvider(
        deviceInfo: DeviceInfo,
        storage: KeyValueStorage,
        httpFactory: HTTPClientFactory = defaultHTTPClientFactory
    ) throws -> ADIDataProvider {
        return try ADIDataProvider(
            rawProvider: OmnisetteADIProvider(),
            deviceInfo: deviceInfo,
            storage: storage,
            httpFactory: httpFactory
        )
    }
}
