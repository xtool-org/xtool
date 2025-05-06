//
//  IPAInstaller.swift
//  XKit
//
//  Created by Kabir Oberai on 14/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

public final class IPAInstaller: Sendable {

    private let client: InstallationProxyClient
    public init(connection: Connection) async throws {
        self.client = try await connection.startClient()
    }

    public func install(
        uploaded: IPAUploader.UploadedIPA,
        progress: @escaping @Sendable (InstallationProxyClient.RequestProgress) -> Void
    ) async throws {
        try await client.install(
            package: uploaded.location,
            progress: progress
        )
    }

}
