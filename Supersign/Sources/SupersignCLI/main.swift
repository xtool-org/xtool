import Foundation
import Supersign

defer { defaultHTTPClientFactory.shared.shutdown() }

// nil = EOF
func prompt(_ message: String) -> String? {
    if !message.isEmpty {
        print(message, terminator: "")
    }
    return readLine()
}

func getPassword(_ message: String) -> String? {
    if !message.isEmpty {
        print(message, terminator: "")
    }

    var origAttr = termios()
    tcgetattr(STDIN_FILENO, &origAttr)

    var newAttr = origAttr
    newAttr.c_lflag = newAttr.c_lflag & ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &newAttr)

    let password = prompt("")

    tcsetattr(STDIN_FILENO, TCSANOW, &origAttr)
    print()

    return password
}

func chooseNumber(in range: Range<Int>) -> Int {
    print("Choice (\(range.lowerBound)-\(range.upperBound - 1)): ", terminator: "")
    guard let choice = readLine().flatMap(Int.init), range.contains(choice)
        else { return chooseNumber(in: range) }
    return choice
}

func choose<T>(
    from elements: [T],
    onNoElement: () throws -> T,
    multiPrompt: @autoclosure () -> String,
    formatter: (T) throws -> String
) rethrows -> T {
    switch elements.count {
    case 0:
        return try onNoElement()
    case 1:
        return elements[0]
    default:
        print(multiPrompt())
        try elements.enumerated().forEach { index, element in
            try print("\(index): \(formatter(element))")
        }
        let choice = chooseNumber(in: elements.indices)
        return elements[choice]
    }
}

class SupersignCLIDelegate: SuperchargeInstallerDelegate {
    let completion: () -> Void
    init(completion: @escaping () -> Void) {
        self.completion = completion
    }

    func fetchCode(completion: @escaping (String?) -> Void) {
        let code = prompt("Code: ")
        completion(code)
    }

    func fetchTeam(fromTeams teams: [DeveloperServicesTeam], completion: @escaping (DeveloperServicesTeam?) -> Void) {
        let selected = choose(
            from: teams,
            onNoElement: { fatalError() },
            multiPrompt: "Select a team",
            formatter: {
                "\($0.name) (\($0.id))"
            }
        )
        completion(selected)
    }

    func presentMessage(_ message: SuperchargeInstaller.Message) {
        switch message {
        case .pairDevice:
            print("\nPlease tap 'trust' on your device...", terminator: "")
        case .unlockDevice:
            print("\nPlease unlock your device...", terminator: "")
        }
        fflush(stdout)
    }

    func dismissMessage() {
        print("\nContinuing...", terminator: "")
        fflush(stdout)
    }

    var prevStage: String?
    var prevProgress: String?

    func installerDidUpdate(toStage stage: String, progress: Double?) {
        let progString: String?
        if let progress = progress {
            let progInt = Int(progress * 100)
            if progInt < 10 {
                progString = "  \(progInt)%"
            } else if progInt < 100 {
                progString = " \(progInt)%"
            } else {
                progString = "\(progInt)%"
            }
        } else {
            progString = nil
        }

        defer {
            prevStage = stage
            prevProgress = progString
        }

        if stage != prevStage {
            if let progString = progString {
                print("\n[\(stage)] \(progString)", terminator: "")
                fflush(stdout)
            } else {
                print("\n===[\(stage)]===", terminator: "")
                fflush(stdout)
            }
        } else if progString != prevProgress {
            if let progString = progString {
                print("\r[\(stage)] \(progString)", terminator: "")
                fflush(stdout)
            } else {
                print("\r[\(stage)]", terminator: "")
                fflush(stdout)
            }
        }
    }

    func installerDidComplete(withResult result: Result<(), Error>) {
        print()
        switch result {
        case .success:
            print("Complete!")
        case .failure(let error):
            print("Failed :(")
            print("Error: \(error)")
        }
        completion()
    }

    func decompress(
        ipa: URL,
        in directory: URL,
        progress: @escaping (Double?) -> Void,
        completion: @escaping (_ success: Bool) -> Void
    ) {
        progress(nil)

        let unzip = Process()
        unzip.launchPath = "/usr/bin/unzip"
        unzip.arguments = ["-q", ipa.path, "-d", directory.path]
        unzip.launch()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { return completion(false) }

        completion(true)
    }

    func compressIfNeeded(payloadDir: URL, progress: @escaping (Double?) -> Void, completion: @escaping (URL?) -> Void) {
        progress(nil)

        let dest = payloadDir.deletingLastPathComponent().appendingPathComponent("app.ipa")

        let zip = Process()
        zip.launchPath = "/usr/bin/zip"
        zip.currentDirectoryPath = payloadDir.deletingLastPathComponent().path
        zip.arguments = ["-yqru0", dest.path, "Payload"]
        zip.launch()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { return completion(nil) }

        completion(dest)
    }
}

class ConnectionDelegate: ConnectionManagerDelegate {
    var onConnect: (([ConnectionManager.Client]) -> Void)?
    init(onConnect: @escaping ([ConnectionManager.Client]) -> Void) {
        self.onConnect = onConnect
    }

    func connectionManager(_ manager: ConnectionManager, clientsDidChangeFrom oldValue: [ConnectionManager.Client]) {
        onConnect?(manager.clients)
        onConnect = nil
    }
}

func main() throws {
    let moduleBundle: Bundle
    #if swift(>=5.5) || os(macOS)
    moduleBundle = Bundle.module
    #else
    moduleBundle = Bundle(url: Bundle.main.url(forResource: "Supersign_SupersignCLI", withExtension: "resources")!)!
    #endif
    let app = moduleBundle.url(forResource: "Supercharge", withExtension: "ipa")!

    guard let username = prompt("Apple ID: "),
          let password = getPassword("Password: ")
    else { return }

    print("Waiting for device to be connected...")
    var clients: [ConnectionManager.Client]!
    let semaphore = DispatchSemaphore(value: 0)
    let connDelegate = ConnectionDelegate { currClients in
        clients = currClients
        semaphore.signal()
    }
    try withExtendedLifetime(ConnectionManager(delegate: connDelegate)) {
        semaphore.wait()
    }

    let client = choose(
        from: clients,
        onNoElement: { fatalError() },
        multiPrompt: "Choose device",
        formatter: { "\($0.deviceName) (\($0.udid))" }
    )

    print("Installing to device: \(client.deviceName) (\(client.udid))")

    let installDelegate = SupersignCLIDelegate {
        semaphore.signal()
    }
    let installer = SuperchargeInstaller(udid: client.udid, appleID: username, password: password, delegate: installDelegate)
    installer.install(ipa: app)
    semaphore.wait()
    _ = installer
}

try main()

//func main() throws {
//    let connManager = try ConnectionManager()
//    sleep(1)
//    print("Connected: \(connManager.clients)")
//
//    let deviceInfo = DeviceInfo.current()!
//    let manager = DeveloperServicesLoginManager(deviceInfo: deviceInfo)
//
//    guard let username = prompt("Username: "),
//          let password = getPassword("Password: ")
//    else { return }
//
//    class TwoFactorFetcher: TwoFactorAuthDelegate {
//        func fetchCode(completion: @escaping (String?) -> Void) {
//            let code = prompt("Code: ")
//            completion(code)
//        }
//    }
//
//    var tokenResult: Result<DeveloperServicesLoginToken, Error>!
//    let fetcher = TwoFactorFetcher()
//    let sem = DispatchSemaphore(value: 0)
//    manager.logIn(withUsername: username, password: password, twoFactorDelegate: fetcher) { result in
//        defer { sem.signal() }
//        tokenResult = result
//    }
//    sem.wait()
//    let token = try tokenResult.get()
//
//    var teamsResult: Result<[DeveloperServicesTeam], Error>!
//    let client = DeveloperServicesClient(loginToken: token, deviceInfo: deviceInfo)
//    client.send(DeveloperServicesListTeamsRequest()) { result in
//        defer { sem.signal() }
//        teamsResult = result
//    }
//    sem.wait()
//    let teams = try teamsResult.get()
//
//    let memManager = MemoryBackedSigningInfoManager()
//    let ctx = try SigningContext(
//        udid: "00008030-001409AA0298802E",
//        teamID: teams[0].id,
//        client: client,
//        signingInfoManager: memManager
//    )
//
//    var signResult: Result<(), Error>!
//    let app = Bundle.module.url(forResource: "Supercharge", withExtension: "app")!
//    print("App: \(app)")
//
//    let tmp = try FileManager.default.makeTemporaryDirectory()
//    defer { try? FileManager.default.removeItem(at: tmp) }
//
//    let copied = tmp.appendingPathComponent("Supercharge.app")
//    try FileManager.default.copyItem(at: app, to: copied)
//
//    Signer(context: ctx).sign(
//        app: copied,
//        status: { status in
//            print("[status] \(status)")
//        },
//        progress: { progress in
//            print("[progress] \(progress)")
//        },
//        completion: { result in
//            defer { sem.signal() }
//            signResult = result
//        }
//    )
//    sem.wait()
//    try signResult.get()
//
//    print("Success!")
//}
//
//try main()

//if #available(macOS 10.12, *) {
//    RunLoop.main.perform(main)
//}
//RunLoop.main.run()

//print("Connecting...")

//let manager = try ConnectionManager()
//Thread.sleep(forTimeInterval: 1)
//print("Clients: \(manager.clients)")

////
////  main.swift
////  SuperchargeInstallerCLI
////
////  Created by Kabir Oberai on 17/06/20.
////  Copyright © 2020 Kabir Oberai. All rights reserved.
////
//
//import Foundation
//import Supersign
//import SwiftyMobileDevice
//
//extension LockdownClient {
//    static let supersignLabel = "supercharge-installer"
//}
//
//struct InstallerError: Error, CustomStringConvertible {
//    let description: String
//    init(_ description: String) {
//        self.description = description
//    }
//}
//
//func printProgress(_ progress: Double, description: String) {
//    print("[\(String(format: "%.2f%%", progress * 100))] \(description)")
//}
//
//func chooseNumber(in range: Range<Int>) -> Int {
//    print("Choice (\(range.lowerBound)-\(range.upperBound - 1)): ", terminator: "")
//    guard let choice = readLine().flatMap(Int.init), range.contains(choice)
//        else { return chooseNumber(in: range) }
//    return choice
//}
//
//func choose<T>(
//    from elements: [T],
//    onNoElement: () throws -> T,
//    multiPrompt: @autoclosure () -> String,
//    formatter: (T) throws -> String
//) rethrows -> T {
//    switch elements.count {
//    case 0:
//        return try onNoElement()
//    case 1:
//        return elements[0]
//    default:
//        print(multiPrompt())
//        try elements.enumerated().forEach { index, element in
//            try print("\(index): \(formatter(element))")
//        }
//        let choice = chooseNumber(in: elements.indices)
//        return elements[choice]
//    }
//}
//
//func performWithRecovery<T>(shouldPrompt: Bool = true, block: () throws -> T) rethrows -> T {
//    func recurse(_ message: String) throws -> T {
//        if shouldPrompt { print(message) }
//        // allow some time before recursing (even if TCO)
//        Thread.sleep(forTimeInterval: 0.5)
//        return try performWithRecovery(shouldPrompt: false, block: block)
//    }
//
//    do {
//        return try block()
//    } catch let error as LockdownClient.Error where error == .pairingDialogResponsePending {
//        return try recurse("Please pair your device...")
//    } catch let error as LockdownClient.Error where error == .passwordProtected {
//        return try recurse("Please unlock your device...")
//    } catch {
//        throw error
//    }
//}
//
//struct IDeviceInfo {
//    let udid: String
//    let pairingKeys: Data
//
//    static func retrieve() throws -> IDeviceInfo {
//        print("Looking for devices...")
//        var devices: [Device]
//        repeat {
//            // using a Set uniques devices that are available via network+usb
//            let udids = try Set(Device.udids()).sorted()
//            devices = udids.compactMap { try? Device(udid: $0) }
//        } while devices.isEmpty
//        print("Connected!")
//        let device = try choose(
//            from: devices,
//            onNoElement: {
//                throw InstallerError("No devices found. Please attach a device and try again.")
//            },
//            multiPrompt: "Select a device",
//            formatter: { device in
//                let client = try LockdownClient(device: device, label: LockdownClient.supersignLabel, performHandshake: false)
//                return try "\(client.deviceName()) (\(device.udid()))"
//            }
//        )
//
//        // we can't reuse the previously created client because we need to perform a handshake this time
//        let client = try performWithRecovery {
//            try LockdownClient(device: device, label: LockdownClient.supersignLabel, performHandshake: true)
//        }
//        let udid = try device.udid()
//
//        try client.setValue(udid, forDomain: "com.apple.mobile.wireless_lockdown", key: "WirelessBuddyID")
//        try client.setValue(true, forDomain: "com.apple.mobile.wireless_lockdown", key: "EnableWifiConnections")
//
//        // now create a new pair record, temporarily removing the existing one. This is necessary
//        // because if two machines try accessing lockdown with the same device wirelessly, it'll
//        // fail during the heartbeat
//        let oldRecord = try USBMux.pairRecord(forUDID: udid)
//        try USBMux.deletePairRecord(forUDID: udid)
//
//        let newRecord: Data
//        do {
//            defer { try? USBMux.savePairRecord(oldRecord, forUDID: udid) }
//            try performWithRecovery { try client.pair() }
//            newRecord = try USBMux.pairRecord(forUDID: udid)
//        }
//
//        return IDeviceInfo(udid: udid, pairingKeys: newRecord)
//    }
//}
//
//class LoginManager: TwoFactorAuthDelegate {
//
//    let deviceInfo: DeviceInfo
//    init(deviceInfo: DeviceInfo) {
//        self.deviceInfo = deviceInfo
//    }
//
//    private func prompt(_ message: String) -> String {
//        print(message, terminator: "")
//        return readLine() ?? prompt(message)
//    }
//
//    func logIn() throws -> (String, DeveloperServicesLoginToken) {
//        let username = prompt("Apple ID: ")
//        let password = String(cString: getpass("Password: "))
//
//        let group = DispatchGroup()
//        group.enter()
//        var result: Result<DeveloperServicesLoginToken, Error>?
//        DeveloperServicesLoginManager(deviceInfo: deviceInfo).logIn(
//            withUsername: username,
//            password: password,
//            twoFactorDelegate: self
//        ) { res in
//            result = res
//            group.leave()
//        }
//        group.wait()
//
//        return (username, try result!.get())
//    }
//
//    func fetchCode(completion: @escaping (String) -> Void) {
//        completion(prompt("2FA Code: "))
//    }
//
//}
//
//func fetchTeam(client: DeveloperServicesClient) throws -> DeveloperServicesTeam {
//    var result: Result<[DeveloperServicesTeam], Error>?
//    let group = DispatchGroup()
//    group.enter()
//    client.send(DeveloperServicesListTeamsRequest()) { res in
//        result = res
//        group.leave()
//    }
//    group.wait()
//    let teams = try result!.get()
//    return try choose(
//        from: teams,
//        onNoElement: {
//            throw InstallerError("Could not find any development teams associated with this Apple ID")
//        },
//        multiPrompt: "Select a team",
//        formatter: { "\($0.name) (\($0.id.rawValue))" }
//    )
//}
//
//func makeAppDir() throws -> URL {
//    let template = URL(fileURLWithPath: "/Users/kabiroberai/Desktop/Supercharge-Template.app")
//
//    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Supercharge-Staging")
//    if FileManager.default.fileExists(atPath: temp.path) {
//        try FileManager.default.removeItem(at: temp)
//    }
//    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: nil)
//
//    let dest = temp.appendingPathComponent("Supercharge.app")
//    try FileManager.default.copyItem(at: template, to: dest)
//    return dest
//}
//
////func package(app: URL) throws -> URL {
////    let tempDir = app.deletingLastPathComponent()
////    let payloadDir = tempDir.appendingPathComponent("Payload")
////    if FileManager.default.fileExists(atPath: payloadDir.path) {
////        try FileManager.default.removeItem(at: payloadDir)
////    }
////    try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true, attributes: nil)
////    try FileManager.default.moveItem(at: app, to: payloadDir.appendingPathComponent(app.lastPathComponent))
////
////    let zipProcess = Process()
////    zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
////    zipProcess.arguments = ["-r", "Supercharge.ipa", payloadDir.lastPathComponent]
////    zipProcess.currentDirectoryURL = tempDir
////    try zipProcess.run()
////    zipProcess.waitUntilExit()
////    guard zipProcess.terminationStatus == 0 else { throw InstallerError("Failed to package signed app") }
////
////    return tempDir.appendingPathComponent("Supercharge.ipa")
////}
//
//func install(
//    app: URL,
//    iDeviceInfo: IDeviceInfo,
//    team: DeveloperServicesTeam,
//    client: DeveloperServicesClient
//) throws {
//    let context = try SigningContext(
//        udid: iDeviceInfo.udid,
//        teamID: team.id,
//        client: client,
//        signingInfoManager: MemoryBackedSigningInfoManager(),
//        platform: .iOS
//    )
//
//    let group = DispatchGroup()
//    var result: Result<(), Error>?
//    var currProgress: Double = 0
//    var currStatus: String?
//    group.enter()
//    Signer(context: context).sign(
//        app: app,
//        status: { status in
//            currStatus = status
//            printProgress(currProgress, description: status)
//        },
//        progress: { progress in
//            currProgress = progress
//            currStatus.map { printProgress(progress, description: $0) }
//        },
//        completion: { res in
//            result = res
//            group.leave()
//        }
//    )
//    group.wait()
//    try result!.get()
//
////    print("Packaging app...")
////    let ipa = try package(app: app)
//
//    group.enter()
//    AppInstaller(app: app, udid: iDeviceInfo.udid, pairingKeys: iDeviceInfo.pairingKeys).install(
//        progress: { stage in
//            printProgress(stage.displayProgress, description: stage.displayName)
//        }, completion: { res in
//            result = res
//            group.leave()
//        }
//    )
//
//    group.wait()
//    try result!.get()
//}
//
//func main() throws {
//    guard let deviceInfo: DeviceInfo = .current() else {
//        throw InstallerError("Failed to fetch hardware info")
//    }
//
//    let iDeviceInfo: IDeviceInfo = try .retrieve()
//
//    let (appleID, token) = try LoginManager(deviceInfo: deviceInfo).logIn()
//    print("Logged in! Fetching teams...")
//    let client = DeveloperServicesClient(loginToken: token, deviceInfo: deviceInfo)
//    let team = try fetchTeam(client: client)
//
//    let appDir = try makeAppDir()
//    let tempDir = appDir.deletingLastPathComponent()
//    defer { try? FileManager.default.removeItem(at: tempDir) }
//
//    let config = Superconfig(
//        udid: iDeviceInfo.udid,
//        pairingKeys: iDeviceInfo.pairingKeys,
//        deviceInfo: deviceInfo,
//        preferredTeamID: team.id.rawValue,
//        appleID: appleID,
//        token: token
//    )
//    try config.save(inAppDir: appDir)
//
//    try install(app: appDir, iDeviceInfo: iDeviceInfo, team: team, client: client)
//}
//
//do {
//    try main()
//} catch {
//    print("Error: \(error)")
//}
