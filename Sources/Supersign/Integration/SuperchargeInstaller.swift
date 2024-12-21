//
//  Installer.swift
//  Supercharge Installer
//
//  Created by Kabir Oberai on 19/06/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import Foundation
import SwiftyMobileDevice
import ConcurrencyExtras

extension LockdownClient {
    static let installerLabel = "supersign"
}

#if !os(iOS)

public protocol IntegratedInstallerDelegate: AnyObject, Sendable {

    func setPresentedMessage(_ message: IntegratedInstaller.Message?)
    func installerDidUpdate(toStage stage: String, progress: Double?)

    // defaults to always returning true
    func confirmRevocation(of certificates: [DeveloperServicesCertificate]) async -> Bool

    /// Decompress the zipped ipa file
    ///
    /// - Parameter ipa: The `ipa` file to decompress.
    /// - Parameter directory: The directory into which `ipa` should be decompressed.
    /// - Parameter progress: A closure to which the callee can provide progress updates.
    /// - Parameter currentProgress: The current progress, or `nil` to indicate it is indeterminate.
    func decompress(
        ipa: URL,
        in directory: URL,
        progress: @escaping @Sendable (_ currentProgress: Double?) -> Void
    ) async throws

    // `compress` is required because the only way to upload symlinks via afc is by
    // putting them in a zip archive (afc_make_symlink was disabled due to security or
    // something)

    /// Compress the app before installation.
    ///
    /// - Parameter payloadDir: The `Payload` directory which is to be compressed.
    /// - Parameter progress: A closure to which the callee can provide progress updates.
    /// - Parameter currentProgress: The current progress, or `nil` to indicate it is indeterminate.
    func compress(
        payloadDir: URL,
        progress: @escaping @Sendable (_ currentProgress: Double?) -> Void
    ) async throws -> URL

}

extension IntegratedInstallerDelegate {
    public func confirmRevocation(of certificates: [DeveloperServicesCertificate]) async -> Bool {
        true
    }
}

public actor IntegratedInstaller {

    public enum Error: LocalizedError {
        case alreadyInstalling
        case deviceInfoFetchFailed
        case noTeamFound
        case appExtractionFailed
        case appCorrupted
        case appPackagingFailed
        case pairingFailed

        public var errorDescription: String? {
            "Installer.Error.\(self)"
        }
    }

    public enum Message {
        case pairDevice
        case unlockDevice
    }

    let udid: String
    let lookupMode: LookupMode
    let appleID: String
    let token: DeveloperServicesLoginToken
    let teamID: DeveloperServicesTeam.ID
    let configureDevice: Bool
    let storage: KeyValueStorage
    public weak var delegate: IntegratedInstallerDelegate?

    private var appInstaller: AppInstaller?

    private let tempDir = FileManager.default.temporaryDirectoryShim
        .appendingPathComponent("com.kabiroberai.Supercharge-Installer.Staging")

    private var stage: String?

    private nonisolated let updateTask = LockIsolated<Task<Void, Never>?>(nil)

    private nonisolated func queueUpdateTask(
        _ perform: @escaping @Sendable (isolated IntegratedInstaller) async -> Void
    ) {
        updateTask.withValue { task in
            task = Task { [prev = task] in
                await prev?.value
                await perform(self)
            }
        }
    }

    private func updateStage(
        to stage: String,
        initialProgress: Double? = 0
    ) async throws {
        await Task.yield()
        try Task.checkCancellation()
        updateStageIgnoringCancellation(to: stage, initialProgress: initialProgress)
    }

    private func updateStageIgnoringCancellation(
        to stage: String,
        initialProgress: Double? = 0
    ) {
        guard self.stage != stage else { return }
        self.stage = stage
        delegate?.installerDidUpdate(toStage: stage, progress: initialProgress)
    }

    private func updateProgress(to progress: Double?) async throws {
        await Task.yield()
        try Task.checkCancellation()
        updateProgressIgnoringCancellation(to: progress)
    }

    private func updateProgressIgnoringCancellation(to progress: Double?) {
        guard let stage = stage else {
            preconditionFailure("Cannot change progress without setting stage at least once")
        }
        delegate?.installerDidUpdate(toStage: stage, progress: progress)
    }

    public init(
        udid: String,
        lookupMode: LookupMode,
        appleID: String,
        token: DeveloperServicesLoginToken,
        teamID: DeveloperServicesTeam.ID,
        configureDevice: Bool,
        storage: KeyValueStorage,
        delegate: IntegratedInstallerDelegate
    ) {
        self.udid = udid
        self.lookupMode = lookupMode
        self.appleID = appleID
        self.token = token
        self.teamID = teamID
        self.configureDevice = configureDevice
        self.storage = storage
        self.delegate = delegate
    }

    private func performWithRecovery<T>(
        repeatAfter: TimeInterval = 0.1,
        block: () async throws -> sending T
    ) async throws -> sending T {
        var currMessage: Message?

        defer {
            if currMessage != nil {
                delegate?.setPresentedMessage(nil)
            }
        }

        while true {
            let nextMessage: Message
            do {
                return try await block()
            } catch let error as LockdownClient.Error where error == .pairingDialogResponsePending {
                nextMessage = .pairDevice
            } catch let error as LockdownClient.Error where error == .passwordProtected {
                nextMessage = .unlockDevice
            }
            if currMessage != nextMessage {
                delegate?.setPresentedMessage(nextMessage)
                currMessage = nextMessage
            }
            try await Task.sleep(seconds: repeatAfter)
        }
    }

    private func fetchPairingKeys(with lockdownClient: LockdownClient) async throws -> Data {
        try lockdownClient.setValue(udid, forDomain: "com.apple.mobile.wireless_lockdown", key: "WirelessBuddyID")
        try lockdownClient.setValue(true, forDomain: "com.apple.mobile.wireless_lockdown", key: "EnableWifiConnections")

        try await updateProgress(to: 2/3)

        // now create a new pair record based off the existing one, but replacing the
        // SystemBUID and HostID. This is necessary because if two machines with the
        // same HostID try accessing lockdown with the same device wirelessly, it'll
        // fail during the heartbeat. The SystemBUID also has to be different because
        // we can only have one HostID per SystemBUID on iOS 15+
        let oldRecord = try USBMux.pairRecord(forUDID: udid)

        var plistFormat: PropertyListSerialization.PropertyListFormat = .xml
        guard var plist = try PropertyListSerialization
                .propertyList(from: oldRecord, options: [], format: &plistFormat)
                as? [String: Any],
              let deviceCert = plist["DeviceCertificate"] as? Data,
              let hostCert = plist["HostCertificate"] as? Data,
              let rootCert = plist["RootCertificate"] as? Data,
              let systemBUIDString = plist["SystemBUID"] as? String,
              let systemBUID = UUID(uuidString: systemBUIDString)
        else { throw Error.pairingFailed }

        var bytes = systemBUID.uuid
        // byte 7 MSBs 4-7 are the uuid version field
        // byte 8 MSBs 6-7 are the variant field
        // everything else *should* be fair game to modify
        // for UUID v4
        bytes.0 = ~bytes.0
        let newSystemBUID = UUID(uuid: bytes).uuidString
        plist["SystemBUID"] = newSystemBUID

        let hostID = UUID().uuidString
        plist["HostID"] = hostID

        let record = LockdownClient.PairRecord(
            deviceCertificate: deviceCert,
            hostCertificate: hostCert,
            rootCertificate: rootCert,
            hostID: hostID,
            systemBUID: newSystemBUID
        )
        try await performWithRecovery {
            try lockdownClient.pair(withRecord: record)
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: plistFormat, options: 0
        )

        try await updateProgress(to: 1)

        return data
    }

    @discardableResult
    public func install(app: URL) async throws -> String {
        try await self.updateStage(to: "Unpacking app", initialProgress: nil)

        if FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        switch app.pathExtension {
        case "ipa":
            try await delegate?.decompress(
                ipa: app,
                in: tempDir,
                progress: { progress in
                    self.queueUpdateTask {
                        $0.updateProgressIgnoringCancellation(to: progress)
                    }
                }
            )
        case "app":
            let payload = tempDir.appendingPathComponent("Payload")
            let dest = payload.appendingPathComponent(app.lastPathComponent)
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: app, to: dest)
        default:
            throw Error.appExtractionFailed
        }

        try await self.updateProgress(to: 1)

        let payload = self.tempDir.appendingPathComponent("Payload")
        guard let appDir = payload.implicitContents.first(where: { $0.pathExtension == "app" })
            else { throw Error.appExtractionFailed }

        guard let deviceInfo = DeviceInfo.current() else {
            throw Error.deviceInfoFetchFailed
        }

        try await updateStage(to: "Logging in")

        try await self.updateStage(to: "Preparing device")

        // TODO: Maybe use `Connection` here instead of creating the lockdown
        // client manually?
        let device = try Device(udid: udid, lookupMode: lookupMode)

        try await updateProgress(to: configureDevice ? 1/3 : 1/2)

        // we can't reuse any previously created client because we need to perform a handshake this time
        let lockdownClient = try await performWithRecovery {
            try LockdownClient(
                device: device,
                label: LockdownClient.installerLabel,
                performHandshake: true
            )
        }

        let deviceName = try lockdownClient.deviceName()

        let pairingKeys: Data? = if configureDevice {
            try await fetchPairingKeys(with: lockdownClient)
        } else {
            nil
        }

        try await updateProgress(to: 1)

        let anisetteProvider = try ADIDataProvider.adiProvider(deviceInfo: deviceInfo, storage: storage)
        let client = DeveloperServicesClient(
            loginToken: token,
            deviceInfo: deviceInfo,
            anisetteProvider: anisetteProvider
        )

        let context = try SigningContext(
            udid: udid,
            deviceName: deviceName,
            teamID: teamID,
            client: client,
            signingInfoManager: KeyValueSigningInfoManager(storage: storage),
            platform: .iOS
        )

        let signer = Signer(context: context) { certs in
            await self.delegate?.confirmRevocation(of: certs) ?? false
        }
        let bundleID = try await signer.sign(
            app: appDir,
            status: { @Sendable status in
                self.queueUpdateTask {
                    $0.updateStageIgnoringCancellation(to: status)
                }
            },
            progress: { progress in
                self.queueUpdateTask {
                    $0.updateProgressIgnoringCancellation(to: progress)
                }
            },
            didProvision: { @Sendable [self] in
                if let pairingKeys = pairingKeys {
                    let info = try context.signingInfoManager.info(forTeamID: context.teamID)
                    try Superconfig(
                        udid: udid,
                        pairingKeys: pairingKeys,
                        deviceInfo: deviceInfo,
                        preferredTeamID: teamID.rawValue,
                        preferredSigningInfo: info,
                        appleID: appleID,
                        provisioningData: anisetteProvider.provisioningData(),
                        token: token
                    ).save(inAppDir: appDir)
                }
            }
        )

        try await self.updateStage(to: "Packaging", initialProgress: nil)

        let ipa = try await delegate?.compress(
            payloadDir: appDir.deletingLastPathComponent(),
            progress: { progress in
                self.queueUpdateTask {
                    $0.updateProgressIgnoringCancellation(to: progress)
                }
            }
        )

        try await self.updateProgress(to: 1)

        let appInstaller = AppInstaller(ipa: ipa!, udid: udid, connectionPreferences: .init(lookupMode: lookupMode))
        self.appInstaller = appInstaller
        try await appInstaller.install(
            progress: { stage in
                self.queueUpdateTask {
                    $0.updateStageIgnoringCancellation(to: stage.displayName)
                    $0.updateProgressIgnoringCancellation(to: stage.displayProgress)
                }
            }
        )
        return bundleID
    }

}

#endif
