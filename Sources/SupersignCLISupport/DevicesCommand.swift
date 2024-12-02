import Foundation
import Supersign
import ArgumentParser

extension ConnectionManager.SearchMode: EnumerableFlag {
//    public static func name(for value: ConnectionManager.SearchMode) -> NameSpecification {
//        [.short, .long]
//    }
}

struct DevicesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List devices"
    )

    @Flag(help: "Which devices to search for") var search: ConnectionManager.SearchMode = .all

    func run() throws {
        var _clients: [ConnectionManager.Client]!
        let semaphore = DispatchSemaphore(value: 0)
        let connDelegate = ConnectionDelegate { currClients in
            _clients = currClients
            semaphore.signal()
        }
        try withExtendedLifetime(ConnectionManager(searchMode: search, delegate: connDelegate)) {
            semaphore.wait()
        }
        let clients = _clients!
        print(clients.map { "\($0.deviceName) [\($0.connectionType)]: \($0.udid)" }.joined(separator: "\n"))
    }
}
