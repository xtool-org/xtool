//
//  AppInstaller.swift
//  Supersign
//
//  Created by Kabir Oberai on 13/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

public class AppInstaller {

    public enum Error: LocalizedError {
        case invalidURL

        public var errorDescription: String? {
            switch self {
            case .invalidURL:
                return NSLocalizedString(
                    "app_installer.error.invalid_url",
                    value: "Invalid URL",
                    comment: ""
                )
            }
        }
    }

    public enum Stage {
        case connecting(Double)
        case uploading(Double)
        case installing(String, Double?)

        public var displayName: String {
            switch self {
            case .connecting:
                return NSLocalizedString(
                    "app_installer.stage.connecting",
                    value: "Connecting",
                    comment: ""
                )
            case .uploading:
                return NSLocalizedString(
                    "app_installer.stage.uploading",
                    value: "Uploading",
                    comment: ""
                )
            case .installing(let details, _):
                return String.localizedStringWithFormat(
                    NSLocalizedString(
                        "app_installer.stage.installing",
                        value: "Installing: %@",
                        comment: "The %@ represents the stage reported by Apple (eg. VerifyingApplication)"
                    ),
                    details
                )
            }
        }

        public var displayProgress: Double {
            switch self {
            case .connecting(let progress):
                return progress
            case .uploading(let progress):
                return progress
            case .installing(_, let progress):
                return progress ?? 0
            }
        }
    }

    // serial queue
    private let installQueue = DispatchQueue(
        label: "com.kabiroberai.Supersign.install-queue"
    )

    private init() {}
    public static let shared = AppInstaller()

    // synchronous
    private func installSync(
        ipa: URL,
        bundleID: String,
        udid: String,
        pairingKeys: URL,
        progress: @escaping (Stage) -> Void
    ) throws {
        let connection = try Connection(udid: udid, pairingKeys: pairingKeys) {
            progress(.connecting($0 * 4/6))
        }
        defer { connection.close() }

        let uploader = try IPAUploader(connection: connection)
        progress(.connecting(5/6))

        // we need to start the installer quickly because sometimes it fails if we do it after
        // uploading the ipa to the device
        let installer = try IPAInstaller(connection: connection)
        progress(.connecting(6/6))

        let uploaded = try uploader.upload(ipa: ipa, withBundleID: bundleID) { currentProgress in
            progress(.uploading(currentProgress))
        }
        defer { uploaded.delete() }

        try installer.install(uploaded: uploaded, bundleID: bundleID) { currentProgress in
            progress(.installing(currentProgress.details, currentProgress.progress))
        }
    }

    public func install(
        ipa: URL,
        bundleID: String,
        udid: String,
        pairingKeys: URL,
        progress: @escaping (Stage) -> Void,
        completion: @escaping (Result<(), Swift.Error>) -> Void
    ) {
        installQueue.async {
            completion(Result {
                try self.installSync(
                    ipa: ipa,
                    bundleID: bundleID,
                    udid: udid,
                    pairingKeys: pairingKeys,
                    progress: progress
                )
            })
        }
    }

}
