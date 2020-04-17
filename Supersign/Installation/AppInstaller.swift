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
        case userCancelled
        case invalidURL

        public var errorDescription: String? {
            switch self {
            case .userCancelled:
                return NSLocalizedString(
                    "app_installer.error.user_cancelled",
                    value: "The user cancelled the operation",
                    comment: ""
                )
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
            case .installing:
                return NSLocalizedString(
                    "app_installer.stage.installing",
                    value: "Installing",
                    comment: ""
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

    private var needsCancellation = false
    // throws `Error.userCancelled` if the user cancelled this operation
    private func cancelPoint() throws {
        if needsCancellation {
            throw Error.userCancelled
        }
    }

    public let ipa: URL
    public let bundleID: String
    public let udid: String
    public let pairingKeys: Data
    public init(
        ipa: URL,
        bundleID: String,
        udid: String,
        pairingKeys: Data
    ) {
        self.ipa = ipa
        self.bundleID = bundleID
        self.udid = udid
        self.pairingKeys = pairingKeys
    }

    #warning("We should have some sort of `static` queue/lock")
    // because if two connections are attempted simultaneously,
    // the heartbeat will fail.

    // synchronous
    private func installSync(
        progress: @escaping (Stage) -> Void
    ) throws {
        defer { needsCancellation = false }
        try cancelPoint()

        let connection = try Connection(udid: udid, pairingKeys: pairingKeys) {
            progress(.connecting($0 * 4/6))
        }
        defer { connection.close() }

        try cancelPoint()

        let uploader = try IPAUploader(connection: connection)
        progress(.connecting(5/6))

        try cancelPoint()

        // we need to start the installer quickly because sometimes it fails if we do it after
        // uploading the ipa to the device
        let installer = try IPAInstaller(connection: connection)
        progress(.connecting(6/6))

        try cancelPoint()

        let uploaded = try uploader.upload(ipa: ipa, withBundleID: bundleID) { currentProgress in
            progress(.uploading(currentProgress))
        }
        defer { uploaded.delete() }

        try cancelPoint()

        try installer.install(uploaded: uploaded, bundleID: bundleID) { currentProgress in
            progress(.installing(currentProgress.details, currentProgress.progress))
        }
    }

    public func install(
        progress: @escaping (Stage) -> Void,
        completion: @escaping (Result<(), Swift.Error>) -> Void
    ) {
        installQueue.async {
            completion(Result {
                try self.installSync(progress: progress)
            })
        }
    }

    public func cancel() {
        needsCancellation = true
    }

}
