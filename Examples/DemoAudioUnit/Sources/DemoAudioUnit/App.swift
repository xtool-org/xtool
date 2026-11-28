import AudioToolbox
import AVFAudio
import ExampleSupport
import SwiftUI

@main struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Testing Audio Unit extension...")
                .padding()
                .task {
                    let watchdog = Task { @MainActor in
                        try await Task.sleep(for: .seconds(15))
                        print("Test failed: Audio Unit extension timed out")
                        exit(1)
                    }
                    defer { watchdog.cancel() }
                    do {
                        try await Task { @concurrent in try await runTest() }.value
                        Example.pass()
                    } catch {
                        print("Test failed: \(error)")
                        exit(1)
                    }
                }
        }
    }
}

private func runTest() async throws {
    let description = AudioComponentDescription(
        componentType: kAudioUnitType_Generator,
        componentSubType: 0x70696E67, // ping
        componentManufacturer: 0x58746F6F, // Xtoo
        componentFlags: 0,
        componentFlagsMask: 0
    )
    let audioUnit = try await AUAudioUnit.instantiate(with: description, options: .loadOutOfProcess)
    let channel = audioUnit.messageChannel(for: "xtool.test")
    guard let reply = channel.callAudioUnit?(["message": "ping"]),
          reply["message"] as? String == "pong" else {
        throw StringError("Audio Unit extension did not reply with pong")
    }
    guard let pid = reply["pid"] as? Int,
          pid > 0, pid != Int(ProcessInfo.processInfo.processIdentifier) else {
        throw StringError("Audio Unit did not execute in a separate process")
    }
    print("Audio Unit extension replied pong from PID \(pid)")
    try testAppGroup(channel: channel)
}

private func testAppGroup(channel: any AUMessageChannel) throws {
    // xtool prefixes both the bundle ID and App Group when signing for a device.
    let groupID = "group.\(Bundle.main.bundleIdentifier!).data"
    guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil,
          let defaults = UserDefaults(suiteName: groupID) else {
        throw StringError("Host could not access the App Group")
    }
    // fresh keys ensure a previous run cannot satisfy this test.
    let token = UUID().uuidString
    let requestKey = "request.\(token)"
    let responseKey = "response.\(token)"
    defer {
        defaults.removeObject(forKey: requestKey)
        defaults.removeObject(forKey: responseKey)
    }
    defaults.set("ping", forKey: requestKey)
    let reply = channel.callAudioUnit?([
        "message": "test-app-group", "groupID": groupID, "token": token,
    ])
    guard reply?["message"] as? String == "ok" else {
        throw StringError("App Group extension test failed: \(reply, default: "nil")")
    }
    guard defaults.string(forKey: responseKey) == "pong" else {
        throw StringError("Host did not read pong from App Group defaults")
    }
    print("App Group defaults exchanged ping/pong between host and extension")
}
