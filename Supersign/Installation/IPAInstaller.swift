//
//  IPAInstaller.swift
//  Supersign
//
//  Created by Kabir Oberai on 14/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

public class IPAInstaller {

    private let client: InstallationProxyClient
    public init(connection: Connection) throws {
        self.client = try connection.startClient()
    }

    public func install(
        uploaded: IPAUploader.UploadedIPA,
        bundleID: String,
        progress: @escaping (InstallationProxyClient.InstallProgress) -> Void
    ) throws {
        let options = InstallationProxyClient.Options(additionalOptions: ["CFBundleIdentifier": bundleID])

        var error: Error?
        let semaphore = DispatchSemaphore(value: 0)
        client.install(package: uploaded.location, options: options, progress: progress) { result in
            defer { semaphore.signal() }
            if case let .failure(e) = result { error = e }
        }
        semaphore.wait()

        if let error = error { throw error }
    }

}
