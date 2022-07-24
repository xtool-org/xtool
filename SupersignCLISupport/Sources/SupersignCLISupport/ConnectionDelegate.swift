import Foundation
import Supersign
import ArgumentParser

class ConnectionDelegate: ConnectionManagerDelegate {
    var onConnect: (([ConnectionManager.Client]) -> Void)?
    init(onConnect: @escaping ([ConnectionManager.Client]) -> Void) {
        self.onConnect = onConnect
    }

    func connectionManager(_ manager: ConnectionManager, clientsDidChangeFrom oldValue: [ConnectionManager.Client]) {
        let usableClients = manager.clients
        guard !usableClients.isEmpty else { return }
        onConnect?(usableClients)
        onConnect = nil
    }
}

extension ConnectionManager.Client: ExpressibleByArguments {
    public struct Arguments: ParsableArguments {
        @Option(name: .shortAndLong) var udid: String?
        @Flag var search: ConnectionManager.SearchMode = .all
        public init() {}
    }

    public static func from(_ args: Arguments) throws -> ConnectionManager.Client {
        print("Waiting for device to be connected...")
        var clients: [ConnectionManager.Client]!
        let semaphore = DispatchSemaphore(value: 0)
        let connDelegate = ConnectionDelegate { currClients in
            if let udid = args.udid {
                if let client = currClients.first(where: { $0.udid == udid }) {
                    clients = [client]
                } else {
                    clients = []
                }
            } else {
                clients = currClients
            }
            semaphore.signal()
        }
        try withExtendedLifetime(ConnectionManager(searchMode: args.search, delegate: connDelegate)) {
            semaphore.wait()
        }
        return try Console.choose(
            from: clients,
            onNoElement: { throw ValidationError("Device not found") },
            multiPrompt: "Choose device",
            formatter: { "\($0.deviceName) (\($0.connectionType), udid: \($0.udid))" }
        )
    }
}
