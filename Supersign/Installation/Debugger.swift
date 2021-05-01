//
//  Debugger.swift
//  Supersign
//
//  Created by Kabir Oberai on 26/03/21.
//  Copyright © 2021 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

public final class Debugger {

    private let client: DebugserverClient
    public init(connection: Connection) throws {
        client = try connection.startClient()
        try client.send(command: "QSetMaxPacketSize:", arguments: ["1024"])
    }

    public enum Error: Swift.Error {
        case userCancelled
    }

    // if the receiver is released before the completion handler is called, the
    // method will fail with `Debugger.Error.userCancelled`
    public func attach(toProcess process: String, completion: @escaping (Result<(), Swift.Error>) -> Void) {
        let queue = DispatchQueue(label: "debugger-attach-queue")
        queue.async { [weak self] in
            completion(Result {
                var retainedSelf: Debugger?
                var resp: Data
                repeat {
                    retainedSelf = nil
                    guard let self = self else { throw Error.userCancelled }
                    retainedSelf = self
                    resp = try self.client.send(command: "vAttachWait;", arguments: [process])
                } while resp.isEmpty
                try retainedSelf!.client.send(command: "D", arguments: [])
            })
        }
    }

}
