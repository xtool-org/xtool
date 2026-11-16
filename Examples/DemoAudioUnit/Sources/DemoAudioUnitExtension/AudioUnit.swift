import AudioToolbox
import AVFAudio
import Foundation

@objc(DemoAudioUnitFactory)
final class AudioUnitFactory: NSObject, AUAudioUnitFactory {
    func beginRequest(with context: NSExtensionContext) {}

    func createAudioUnit(with description: AudioComponentDescription) throws -> AUAudioUnit {
        try DemoAudioUnit(componentDescription: description)
    }
}

private final class DemoAudioUnit: AUAudioUnit {
    private var outputs: AUAudioUnitBusArray!

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let bus = try AUAudioUnitBus(format: format)
        self.outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [bus])
    }

    override var outputBusses: AUAudioUnitBusArray { outputs }

    // A silent generator keeps this a valid Audio Unit, although the execution
    // test only instantiates it and exchanges messages; it never starts audio.
    override var internalRenderBlock: AUInternalRenderBlock {
        { _, _, _, _, output, _, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            return noErr
        }
    }

    override func messageChannel(for channelName: String) -> any AUMessageChannel {
        TestMessageChannel()
    }
}

private final class TestMessageChannel: NSObject, AUMessageChannel {
    // AudioToolbox installs this callback when connecting the remote channel,
    // even though this test only sends requests from the host.
    var callHostBlock: CallHostBlock?

    func callAudioUnit(_ message: [AnyHashable: Any]) -> [AnyHashable: Any] {
        if message["message"] as? String == "test-app-group" {
            return ["message": testAppGroup(message)]
        }
        return [
            "message": message["message"] as? String == "ping" ? "pong" : "unknown message",
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ]
    }

    private func testAppGroup(_ message: [AnyHashable: Any]) -> String {
        guard let groupID = message["groupID"] as? String,
              let token = message["token"] as? String,
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil,
              let defaults = UserDefaults(suiteName: groupID) else {
            return "Extension could not access the App Group"
        }
        guard defaults.string(forKey: "request.\(token)") == "ping" else {
            return "Extension did not read ping from App Group defaults"
        }
        defaults.set("pong", forKey: "response.\(token)")
        return "ok"
    }
}
