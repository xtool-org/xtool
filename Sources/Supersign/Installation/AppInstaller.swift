//
//  AppInstaller.swift
//  Supersign
//
//  Created by Kabir Oberai on 13/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice

public actor AppInstaller {

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

    public enum Stage: Sendable {
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
    public func install(progress: @escaping @Sendable (Stage) -> Void) async throws {
        let connection = try await Connection.connection(
            forUDID: udid,
            preferences: connectionPreferences
        ) {
            progress(.connecting($0 * 4/6))
        }

        try Task.checkCancellation()

        let uploader = try await IPAUploader(connection: connection)
        progress(.connecting(5/6))

        try Task.checkCancellation()

        // we need to start the installer quickly because sometimes it fails if we do it after
        // uploading the ipa to the device
        let installer = try await IPAInstaller(connection: connection)
        progress(.connecting(6/6))

        try Task.checkCancellation()

        let uploaded = try await uploader.upload(app: ipa) { currentProgress in
            progress(.uploading(currentProgress))
        }
        defer { uploaded.delete() }

        try Task.checkCancellation()

        try await installer.install(uploaded: uploaded) { currentProgress in
            progress(.installing(currentProgress.details, currentProgress.progress))
        }

        _ = connection
    }

}
