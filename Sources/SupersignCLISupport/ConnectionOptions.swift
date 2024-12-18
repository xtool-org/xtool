import Foundation
import Supersign
import ArgumentParser

struct ConnectionOptions: ParsableArguments {
    struct WithoutSearchMode: ParsableArguments {
        @Option(name: .shortAndLong) var udid: String?
    }

    @OptionGroup var base: WithoutSearchMode
    @Flag var search: ClientDevice.SearchMode = .all

    func client() async throws -> ClientDevice {
        try await base.client(searchMode: search)
    }
}

extension ConnectionOptions.WithoutSearchMode {
    func client(searchMode search: ClientDevice.SearchMode) async throws -> ClientDevice {
        print("Waiting for device to be connected...")

        let stream = try await ClientDevice.search(mode: search)
        for await devices in stream {
            guard !devices.isEmpty else { continue }
            if let udid {
                guard let device = devices.first(where: { $0.udid == udid }) else {
                    continue
                }
                return device
            } else {
                return try await Console.choose(
                    from: devices,
                    onNoElement: { throw Console.Error("Device not found") },
                    multiPrompt: "Choose device",
                    formatter: { "\($0.deviceName) (\($0.connectionType), udid: \($0.udid))" }
                )
            }
        }

        throw CancellationError()
    }
}
