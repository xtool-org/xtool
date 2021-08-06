import Foundation
import Supersign

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
