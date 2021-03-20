//
//  IPAInstaller.swift
//  Supersign
//
//  Created by Kabir Oberai on 14/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

public final class IPAInstaller {

    private let client: InstallationProxyClient
    public init(connection: Connection) throws {
        self.client = try connection.startClient()
    }

    public func install(
        uploaded: IPAUploader.UploadedIPA,
        progress: @escaping (InstallationProxyClient.InstallProgress) -> Void
    ) throws {
        var result: Result<(), Error>?
        let semaphore = DispatchSemaphore(value: 0)
        client.install(
            package: uploaded.location,
            progress: progress,
            completion: { res in
                defer { semaphore.signal() }
                result = res
            }
        )
        semaphore.wait()

        try result!.get()
    }

}
