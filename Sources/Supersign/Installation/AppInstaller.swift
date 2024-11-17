//
//  AppInstaller.swift
//  Supersign
//
//  Created by Kabir Oberai on 13/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

public final class AppInstaller {

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
                // installing is a better name although this is
                // technically uploading
                return NSLocalizedString(
                    "app_installer.stage.installing",
                    value: "Installing",
                    comment: ""
                )
            case .installing:
                return NSLocalizedString(
                    "app_installer.stage.verifying",
                    value: "Verifying",
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
    public let udid: String
    public let connectionPreferences: Connection.Preferences
    public init(
        ipa: URL,
        udid: String,
        connectionPreferences: Connection.Preferences
    ) {
        self.ipa = ipa
        self.udid = udid
        self.connectionPreferences = connectionPreferences
    }

    // synchronous
    private func installSync(progress: @escaping (Stage) -> Void) throws {
        defer { needsCancellation = false }
        try cancelPoint()

        let connection = try Connection.connection(
            forUDID: udid,
            preferences: connectionPreferences
        ) {
            progress(.connecting($0 * 4/6))
        }

        try cancelPoint()

        let uploader = try IPAUploader(connection: connection)
        progress(.connecting(5/6))

        try cancelPoint()

        // we need to start the installer quickly because sometimes it fails if we do it after
        // uploading the ipa to the device
        let installer = try IPAInstaller(connection: connection)
        progress(.connecting(6/6))

        try cancelPoint()

        let uploaded = try uploader.upload(app: ipa) { currentProgress in
            progress(.uploading(currentProgress))
        }
        defer { uploaded.delete() }

        try cancelPoint()

        try installer.install(uploaded: uploaded) { currentProgress in
            progress(.installing(currentProgress.details, currentProgress.progress))
        }

        _ = connection
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
