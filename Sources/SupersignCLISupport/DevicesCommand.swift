import Foundation
import Supersign
import ArgumentParser

extension ClientDevice.SearchMode: EnumerableFlag {
//    public static func name(for value: ConnectionManager.SearchMode) -> NameSpecification {
//        [.short, .long]
//    }
}

struct DevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List devices"
    )

    @Flag(help: "Which devices to search for") var search: ClientDevice.SearchMode = .all
    @Flag(
        inversion: .prefixedNo,
        help: "If no devices are found at first, wait until at least one is connected."
    ) var wait = true

    func run() async throws {
        var shouldPrint = true
        var foundDevices: [ClientDevice] = []
        for await devices in try await ClientDevice.search(mode: search) {
            if !devices.isEmpty {
                foundDevices = devices
                break
            }
            guard wait else { break }
            if shouldPrint {
                shouldPrint = false
                print("Waiting for devices to be connected...")
            }
        }

        print(foundDevices.map { "\($0.deviceName) [\($0.connectionType)]: \($0.udid)" }.joined(separator: "\n"))
    }
}
