import Foundation
import SwiftyMobileDevice

public struct ClientDevice: Sendable {
    public enum SearchMode: CaseIterable, Sendable {
        case usb
        case network
        case all

        fileprivate func allows(_ connectionType: ConnectionType) -> Bool {
            switch self {
            case .usb:
                return connectionType == .usb
            case .network:
                return connectionType == .network
            case .all:
                return true
            }
        }
    }

    private let key: ConnectionManager.ConnectionKey
    private let value: ConnectionManager.ConnectionValue

    public var udid: String { key.udid }
    public var connectionType: ConnectionType { key.connectionType }
    public var device: Device { value.device }
    public var deviceName: String { value.deviceName }

    fileprivate init(key: ConnectionManager.ConnectionKey, value: ConnectionManager.ConnectionValue) {
        self.key = key
        self.value = value
    }

    public static func search(mode: SearchMode = .all) async throws -> AsyncStream<[ClientDevice]> {
        try await ConnectionManager(searchMode: mode).clients
    }
}

private actor ConnectionManager {
    fileprivate struct ConnectionKey: Hashable, Equatable, Comparable {
        let udid: String
        let connectionType: ConnectionType

        private static func precedence(for connectionType: ConnectionType) -> Int {
            switch connectionType {
            case .network: return 0
            case .usb: return 1
            }
        }

        static func < (lhs: ConnectionManager.ConnectionKey, rhs: ConnectionManager.ConnectionKey) -> Bool {
            lhs.udid < rhs.udid ||
                (lhs.udid == rhs.udid
                    && precedence(for: lhs.connectionType) < precedence(for: rhs.connectionType))
        }
    }

    fileprivate struct ConnectionValue: Sendable {
        let device: Device
        let deviceName: String

        init(key: ConnectionKey) throws {
            let deviceConnectionType: ConnectionType
            switch key.connectionType {
            case .network:
                deviceConnectionType = .network
            case .usb:
                deviceConnectionType = .usb
            }
            let device = try Device(udid: key.udid, lookupMode: .only(deviceConnectionType))
            let client = try LockdownClient(
                device: device,
                label: LockdownClient.installerLabel,
                performHandshake: false
            )
            let deviceName = try client.deviceName()

            self.device = device
            self.deviceName = deviceName
        }
    }

    private var clientsDict: [ConnectionKey: ConnectionValue] {
        didSet {
            clientsDidChange()
        }
    }

    private var subscription: Task<Void, Never>?
    private let continuation: AsyncStream<[ClientDevice]>.Continuation

    let searchMode: ClientDevice.SearchMode
    let clients: AsyncStream<[ClientDevice]>

    private func clientsDidChange() {
        continuation.yield(clientsDict.sorted { $0.0 < $1.0 }.map(ClientDevice.init))
    }

    init(searchMode: ClientDevice.SearchMode = .all) async throws {
        self.searchMode = searchMode
        self.clientsDict = Dictionary(try USBMux.allDevices().compactMap { dev -> (ConnectionKey, ConnectionValue)? in
            guard searchMode.allows(dev.connectionType) else { return nil }
            let key = ConnectionKey(udid: dev.udid, connectionType: dev.connectionType)
            return try (key, ConnectionValue(key: key))
        }) { _, b in b }

        let events = try USBMux.subscribe()

        (clients, continuation) = AsyncStream.makeStream()

        clientsDidChange()

        subscription = Task { [events] in
            for await event in events {
                handleEvent(event)
            }
        }
    }

    private func handleEvent(_ event: USBMux.Event) {
        let connectionType = event.device.connectionType
        guard searchMode.allows(connectionType) else { return }
        let udid = event.device.udid
        let key = ConnectionKey(udid: udid, connectionType: connectionType)
        switch event.kind {
        case .removed:
            clientsDict[key] = nil
        case .paired:
            return
        case .added:
            clientsDict[key] = try? ConnectionValue(key: key)
        }
    }

}
