//
//  ConnectionManager.swift
//  Supercharge Installer
//
//  Created by Kabir Oberai on 19/06/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

public protocol ConnectionManagerDelegate: AnyObject {
    func connectionManager(_ manager: ConnectionManager, clientsDidChangeFrom oldValue: [ConnectionManager.Client])
}

public class ConnectionManager {

    fileprivate struct ConnectionKey: Hashable, Equatable {
        let udid: String
        /* let connectionType: USBMux.ConnectionType */
    }

    fileprivate struct ConnectionValue {
        let lockdownClient: LockdownClient
        let deviceName: String
    }

    public struct Client {
        public let udid: String
        public let deviceName: String

        fileprivate init(key: ConnectionKey, value: ConnectionValue) {
            self.udid = key.udid
            self.deviceName = value.deviceName
        }

        public func isEquivalent(to other: Client) -> Bool {
            udid == other.udid
        }
    }

    private var clientsDict: [ConnectionKey: ConnectionValue] = [:] {
        didSet {
            clientsDidChange()
        }
    }

    public private(set) var clients: [Client] = [] {
        didSet {
            delegate?.connectionManager(self, clientsDidChangeFrom: oldValue)
        }
    }

    private var token: USBMux.SubscriptionToken?

    public weak var delegate: ConnectionManagerDelegate?

    private func clientsDidChange() {
        clients = clientsDict.sorted { $0.0.udid < $1.0.udid }.map(Client.init)
    }

    public init(delegate: ConnectionManagerDelegate? = nil) throws {
        self.delegate = delegate
        self.token = try USBMux.subscribe { [weak self] event in
            guard let self = self else { return }
            self.handleEvent(event)
        }
    }

    private func handleEvent(_ event: USBMux.Event) {
        // only handle USB. WiFi won't work because we can't re-pair over wifi afaik
        guard event.device.connectionType == .usb else { return }
        let udid = event.device.udid
        let key = ConnectionKey(udid: udid)
        switch event.kind {
        case .removed:
            clientsDict[key] = nil
        case .paired:
            return
        case .added:
            guard let device = try? Device(udid: udid),
                let client = try? LockdownClient(
                    device: device,
                    label: LockdownClient.installerLabel,
                    performHandshake: false
                ),
                let deviceName = try? client.deviceName()
                else { return }
            clientsDict[key] = ConnectionValue(lockdownClient: client, deviceName: deviceName)
        }
    }

    deinit { try? token.map(USBMux.unsubscribe(withToken:)) }

}
