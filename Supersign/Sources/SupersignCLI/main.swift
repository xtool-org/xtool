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

    func setPresentedMessage(_ message: SuperchargeInstaller.Message?) {
        let text: String
        switch message {
        case .pairDevice:
            text = "Please tap 'trust' on your device..."
        case .unlockDevice:
            text = "Please unlock your device..."
        case nil:
            text = "Continuing..."
        }
        print("\n\(text)", terminator: "")
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
                print("\n[\(stage)] ...", terminator: "")
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
        print("\n")
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

    func compress(payloadDir: URL, progress: @escaping (Double?) -> Void, completion: @escaping (URL?) -> Void) {
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
        let usableClients = manager.clients
        guard !usableClients.isEmpty else { return }
        onConnect?(usableClients)
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
    try withExtendedLifetime(ConnectionManager(usbOnly: true, delegate: connDelegate)) {
        semaphore.wait()
    }

    let client = choose(
        from: clients,
        onNoElement: { fatalError() },
        multiPrompt: "Choose device",
        formatter: { "\($0.deviceName) (udid: \($0.udid))" }
    )

    print("Installing to device: \(client.deviceName) (udid: \(client.udid))")

    let installDelegate = SupersignCLIDelegate {
        semaphore.signal()
    }
    let installer = SuperchargeInstaller(udid: client.udid, appleID: username, password: password, delegate: installDelegate)
    installer.install(ipa: app)
    semaphore.wait()
    _ = installer
}

try main()
