//
//  Debugger.swift
//  Supersign
//
//  Created by Kabir Oberai on 26/03/21.
//  Copyright © 2021 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

public actor Debugger {

    private let client: DebugserverClient
    public init(connection: Connection) async throws {
        client = try await connection.startClient()
        try client.send(command: "QSetMaxPacketSize:", arguments: ["1024"])
    }

    public enum Error: Swift.Error {
        case userCancelled
    }

    // if the receiver is released before the completion handler is called, the
    // method will fail with `Debugger.Error.userCancelled`
    public func attach(toProcess process: String) async throws {
        var resp: Data
        repeat {
            try Task.checkCancellation()
            resp = try self.client.send(command: "vAttachWait;", arguments: [process])
        } while resp.isEmpty
        try self.client.send(command: "D", arguments: [])
    }

}
