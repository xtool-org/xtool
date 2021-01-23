//
//  Installer.swift
//  Supercharge Installer
//
//  Created by Kabir Oberai on 19/06/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import Foundation
import Supersign
import SwiftyMobileDevice

extension LockdownClient {
    static let installerLabel = "supersign-installer"
}

protocol InstallerDelegate: class {
    func fetchCode(completion: @escaping (String?) -> Void)
    func fetchTeam(fromTeams teams: [DeveloperServicesTeam], completion: @escaping (DeveloperServicesTeam?) -> Void)
    func presentMessage(_ message: Installer.Message)
    func dismissMessage()
    func installerDidUpdate(toStage stage: String, progress: Double?)
    func installerDidComplete(withResult result: Result<(), Error>)

    /// Decompress the zipped ipa file
    ///
    /// - Parameter ipa: The `ipa` file to decompress.
    /// - Parameter directory: The directory into which `ipa` should be decompressed.
    /// - Parameter progress: A closure to which the callee can provide progress updates.
    /// - Parameter currentProgress: The current progress, or `nil` to indicate it is indeterminate.
    /// - Parameter completion: A completion handler to call once decompression is finished.
    /// - Parameter success: Whether or not extraction was successful.
    func decompress(
        ipa: URL,
        in directory: URL,
        progress: @escaping (_ currentProgress: Double?) -> Void,
        completion: @escaping (_ success: Bool) -> Void
    )

    /// An opportunity for delegates to compress the app before installation.
    ///
    /// - Parameter payloadDir: The `Payload` directory which is to be compressed.
    /// - Parameter progress: A closure to which the callee can provide progress updates.
    /// - Parameter currentProgress: The current progress, or `nil` to indicate it is indeterminate.
    /// - Parameter completion: A completion handler to call with the compressed file's URL.
    /// - Parameter url: The URL of the compressed file. The caller is responsible for cleaning this
    /// up once installation is complete. Pass `nil` to skip compression.
    ///
    /// - Note: The default implementation of this function simply calls `completion` with a
    /// `nil` value for `url`.
    func compressIfNeeded(
        payloadDir: URL,
        progress: @escaping (_ currentProgress: Double?) -> Void,
        completion: @escaping (_ url: URL?) -> Void
    )
}

extension InstallerDelegate {
    func compressIfNeeded(
        payloadDir: URL,
        progress: @escaping (Double?) -> Void,
        completion: @escaping (URL?) -> Void
    ) {
        completion(nil)
    }
}

final class Installer {

    enum Error: LocalizedError {
        case alreadyInstalling
        case deviceInfoFetchFailed
        case noTeamFound
        case userCancelled
        case appExtractionFailed
        case appCorrupted
        case appPackagingFailed

        var errorDescription: String? {
            "Installer.Error.\(self)"
        }
    }

    struct DeviceInfoError: LocalizedError {
        let info: String

        var errorDescription: String? {
            "Device info: \(info)"
        }
    }

    enum Message {
        case pairDevice
        case unlockDevice
    }

    let udid: String
    let appleID: String
    let password: String
    weak var delegate: InstallerDelegate?

    private var appInstaller: AppInstaller?

    private let tempDir = FileManager.default.temporaryDirectoryShim
        .appendingPathComponent("com.kabiroberai.Supercharge-Installer.Staging")
    private let installQueue =
        DispatchQueue(label: "com.kabiroberai.Supercharge-Installer.install-queue", qos: .userInitiated, attributes: [])

    private enum ExecutionState {
        case running
        case complete
    }

    private var executionStateLock = NSLock()
    private var executionState: ExecutionState = .running

    private func shouldContinue() -> Bool {
        executionStateLock.lock()
        defer { executionStateLock.unlock() }
        switch executionState {
        case .running:
            return true
        case .complete:
            return false
        }
    }

    private func completion(_ result: Result<(), Swift.Error>) {
        executionStateLock.lock()
        defer { executionStateLock.unlock() }
        guard executionState != .complete else { return }
        try? FileManager.default.removeItem(at: tempDir)
        executionState = .complete
        delegate?.installerDidComplete(withResult: result)
        delegate = nil
    }

    func cancel() {
        completion(.failure(Error.userCancelled))
    }

    private var stage: String?
    private func updateStage(to stage: String, ignoreCancellation: Bool = false) -> Bool {
        guard ignoreCancellation || shouldContinue() else { return false }
        self.stage = stage
        delegate?.installerDidUpdate(toStage: stage, progress: 0)
        return true
    }
    private func updateProgress(to progress: Double?, ignoreCancellation: Bool = false) -> Bool {
        guard ignoreCancellation || shouldContinue() else { return false }
        guard let stage = stage else {
            preconditionFailure("Cannot change progress without setting stage at least once")
        }
        delegate?.installerDidUpdate(toStage: stage, progress: progress)
        return true
    }

    init(
        udid: String,
        appleID: String,
        password: String,
        delegate: InstallerDelegate
    ) {
        self.udid = udid
        self.appleID = appleID
        self.password = password
        self.delegate = delegate
    }

    private func performWithRecovery<T>(hasPrompted: Bool = false, block: () throws -> T) throws -> T {
        guard shouldContinue() else { throw Error.userCancelled }

        func recurse(_ message: Installer.Message) throws -> T {
            if !hasPrompted { delegate?.presentMessage(message) }
            // allow some time before recursing (even if TCO, we should probably not overdo it)
            Thread.sleep(forTimeInterval: 0.5)
            return try performWithRecovery(hasPrompted: true, block: block)
        }

        do {
            let result = try block()
            if hasPrompted { delegate?.dismissMessage() }
            return result
        } catch let error as LockdownClient.Error where error == .pairingDialogResponsePending {
            return try recurse(.pairDevice)
        } catch let error as LockdownClient.Error where error == .passwordProtected {
            return try recurse(.unlockDevice)
        } catch {
            if hasPrompted { delegate?.dismissMessage() }
            throw error
        }
    }

    private func fetchPairingKeys() throws -> Data? {
        let device = try Device(udid: udid)

        guard updateProgress(to: 1/3) else { return nil }

        // we can't reuse any previously created client because we need to perform a handshake this time
        let lockdownClient = try performWithRecovery {
            try LockdownClient(device: device, label: LockdownClient.installerLabel, performHandshake: true)
        }

        try lockdownClient.setValue(udid, forDomain: "com.apple.mobile.wireless_lockdown", key: "WirelessBuddyID")
        try lockdownClient.setValue(true, forDomain: "com.apple.mobile.wireless_lockdown", key: "EnableWifiConnections")

        guard updateProgress(to: 2/3) else { return nil }

        // now create a new pair record, temporarily removing the existing one. This is necessary
        // because if two machines try accessing lockdown with the same device wirelessly, it'll
        // fail during the heartbeat
        let oldRecord = try USBMux.pairRecord(forUDID: udid)
        try USBMux.deletePairRecord(forUDID: udid)
        defer { try? USBMux.savePairRecord(oldRecord, forUDID: udid) }

        try performWithRecovery { try lockdownClient.pair() }
        return try USBMux.pairRecord(forUDID: udid)
    }

    private func install(
        deviceInfo: DeviceInfo,
        token: DeveloperServicesLoginToken,
        client: DeveloperServicesClient,
        team: DeveloperServicesTeam,
        possiblyCompressedApp: URL
    ) {
        guard shouldContinue() else { return }
        executionStateLock.lock()
        defer { executionStateLock.unlock() }
        let appInstaller = AppInstaller(app: possiblyCompressedApp, udid: udid, pairingKeys: ())
        self.appInstaller = appInstaller
        appInstaller.install(
            progress: { stage in
                _ = self.updateStage(to: stage.displayName, ignoreCancellation: true)
                _ = self.updateProgress(to: stage.displayProgress, ignoreCancellation: true)
            },
            completion: completion
        )
    }

    private func packageAndInstall(
        deviceInfo: DeviceInfo,
        token: DeveloperServicesLoginToken,
        client: DeveloperServicesClient,
        team: DeveloperServicesTeam,
        appDir: URL
    ) {
        guard self.updateStage(to: "Packaging app"),
            self.updateProgress(to: nil)
            else { return }

        delegate?.compressIfNeeded(
            payloadDir: appDir.deletingLastPathComponent(),
            progress: { progress in
                _ = self.updateProgress(to: progress, ignoreCancellation: true)
            },
            completion: { url in
                self.installQueue.async {
                    self.install(
                        deviceInfo: deviceInfo,
                        token: token,
                        client: client,
                        team: team,
                        possiblyCompressedApp: url ?? appDir
                    )
                }
            }
        )
    }

    private func install(
        deviceInfo: DeviceInfo,
        token: DeveloperServicesLoginToken,
        client: DeveloperServicesClient,
        team: DeveloperServicesTeam,
        appDir: URL
    ) {
        guard self.updateStage(to: "Preparing device") else { return }

        do {
            guard let pairingKeys = try fetchPairingKeys()
                else { return } // nil: user cancelled
            try Superconfig(
                udid: udid,
                pairingKeys: pairingKeys,
                deviceInfo: deviceInfo,
                preferredTeamID: team.id.rawValue,
                appleID: appleID,
                token: token
            ).save(inAppDir: appDir)
        } catch {
            return completion(.failure(error))
        }

        let context: SigningContext
        do {
            context = try SigningContext(
                udid: udid,
                teamID: team.id,
                client: client,
                signingInfoManager: MemoryBackedSigningInfoManager(),
                platform: .iOS
            )
        } catch {
            return completion(.failure(error))
        }
        let signer = Signer(context: context)
        signer.sign(
            app: appDir,
            status: { status in
                _ = self.updateStage(to: status, ignoreCancellation: true)
            },
            progress: { progress in
                _ = self.updateProgress(to: progress, ignoreCancellation: true)
            }, completion: { result in
                guard result.get(withErrorHandler: self.completion) != nil else { return }
                self.packageAndInstall(
                    deviceInfo: deviceInfo,
                    token: token,
                    client: client,
                    team: team,
                    appDir: appDir
                )
            }
        )
    }

    private func install(deviceInfo: DeviceInfo, token: DeveloperServicesLoginToken, appDir: URL) {
        let client = DeveloperServicesClient(loginToken: token, deviceInfo: deviceInfo)
        client.send(DeveloperServicesListTeamsRequest()) { result in
            guard let teams = result.get(withErrorHandler: self.completion) else { return }
            guard self.updateProgress(to: 1) else { return }
            switch teams.count {
            case 0:
                return self.completion(.failure(Error.noTeamFound))
            case 1:
                self.install(deviceInfo: deviceInfo, token: token, client: client, team: teams[0], appDir: appDir)
            default:
                self.delegate?.fetchTeam(fromTeams: teams) { team in
                    self.installQueue.async {
                        guard let team = team else { return self.completion(.failure(Error.userCancelled)) }
                        self.install(deviceInfo: deviceInfo, token: token, client: client, team: team, appDir: appDir)
                    }
                }
            }
        }
    }

    private func install(decompressionDidSucceed: Bool) {
        let payload = self.tempDir.appendingPathComponent("Payload")
        guard decompressionDidSucceed,
            let appDir = payload.implicitContents.first(where: { $0.pathExtension == "app" })
            else { return self.completion(.failure(Error.appExtractionFailed)) }

        return completion(.failure(DeviceInfoError(info: DeviceInfo.deviceDesc())))

        guard let deviceInfo = DeviceInfo.current() else {
            return completion(.failure(Error.deviceInfoFetchFailed))
        }

        guard updateStage(to: "Logging in") else { return }
        DeveloperServicesLoginManager(deviceInfo: deviceInfo).logIn(
            withUsername: self.appleID,
            password: self.password,
            twoFactorDelegate: self
        ) { result in
            guard let token = result.get(withErrorHandler: self.completion) else { return }
            guard self.updateProgress(to: 1/2) else { return }
            self.install(deviceInfo: deviceInfo, token: token, appDir: appDir)
        }
    }

    private func installOnQueue() {
        guard self.updateStage(to: "Unpacking app") else { return }

        let ipa = Bundle.main.url(forResource: "Supercharge", withExtension: "ipa")!
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return completion(.failure(error))
        }

        delegate?.decompress(
            ipa: ipa,
            in: tempDir,
            progress: { progress in
                _ = self.updateProgress(to: progress, ignoreCancellation: true)
            },
            completion: { success in
                guard self.shouldContinue() else { return self.completion(.failure(Error.userCancelled)) }
                self.installQueue.async {
                    self.install(decompressionDidSucceed: success)
                }
            }
        )
    }

    func install() {
        installQueue.async {
            self.installOnQueue()
        }
    }

}

extension Installer: TwoFactorAuthDelegate {
    func fetchCode(completion: @escaping (String?) -> Void) {
        delegate?.fetchCode { code in
            self.installQueue.async {
                completion(code)
            }
        }
    }
}
