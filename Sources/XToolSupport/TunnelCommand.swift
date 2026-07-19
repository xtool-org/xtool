import Foundation
import XKit
import ArgumentParser

/// Diagnostic command for the iOS 17.4+ RSD tunnel work (`Sources/XKit/Testing/Tunnel/`): opens
/// the CoreDeviceProxy tunnel, creates the TUN device, and prints the RSD service directory
/// reachable over it. Not yet wired to `xtool test` -- this is the real-hardware checkpoint for
/// the tunnel/RSD layers before connecting them to the existing DTX/testmanagerd code.
struct TunnelRSDTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tunnel-rsd-test",
        abstract: "Diagnostic: establish the iOS 17+ CoreDeviceProxy tunnel and print the RSD service list",
        discussion: """
        Opens the lockdown-exposed CoreDeviceProxy service, performs the CDTunnel parameter \
        exchange, creates a kernel TUN device (requires CAP_NET_ADMIN -- run \
        `sudo setcap cap_net_admin+ep <path to xtool binary>` first), and looks up the device's \
        RSD service directory over it.
        """
    )

    @OptionGroup var connectionOptions: ConnectionOptions

    func run() async throws {
        let client = try await connectionOptions.client()
        let connection = try await Connection.connection(
            forUDID: client.udid,
            preferences: .init(lookupMode: .only(client.connectionType))
        ) { _ in }

        print("Opening CoreDeviceProxy tunnel...")
        let tunnel = try CoreDeviceProxyTunnel.connect(connection: connection)
        defer { tunnel.close() }
        print("Tunnel up: address=\(tunnel.address) rsdPort=\(tunnel.rsdPort)")

        print("Connecting to RSD over the tunnel...")
        let socket = try PosixTCPSocket(address: tunnel.address, port: tunnel.rsdPort)
        let xpc = try RemoteXPCConnection(stream: socket)
        let handshake = try RSDHandshake.perform(over: xpc)

        print("Device UDID (via RSD): \(handshake.udid)")
        print("Services (\(handshake.services.count)):")
        for (name, entry) in handshake.services.sorted(by: { $0.key < $1.key }) {
            print("  \(name): \(entry.port)")
        }
        if let port = handshake.port(for: "com.apple.dt.testmanagerd.remote") {
            print("\nFound com.apple.dt.testmanagerd.remote at port \(port)")
        } else {
            print("\ncom.apple.dt.testmanagerd.remote not found in RSD service list")
        }

        // Exercise the actual DTX/testmanagerd handshake over the tunnel -- a bogus bundle ID
        // means this will fail at the launchRunner step (no such app installed), but by then both
        // testmanagerd DTX sessions (control + exec) will have already completed for real. This
        // is the real-hardware checkpoint for whether the classic-path "runner never opens its
        // channel" mystery is code-level or device/iOS-16.7-specific -- if it reproduces here too
        // (a fully-installed runner needed to see that far), that's still one step further than
        // this diagnostic goes today.
        print("\nExercising testmanagerd DTX handshake over the tunnel...")
        let productVersion = try await connection.client.value(ofType: String.self, forDomain: nil, key: "ProductVersion")
        let session = TestManagerdSession(
            connection: connection,
            productVersion: productVersion,
            tunnel: .init(tunnel: tunnel, rsd: handshake)
        )
        do {
            _ = try await session.start(runnerBundleID: "com.xtool.tunnel-diagnostic-nonexistent", testBundleName: "Dummy")
        } catch {
            print("start() ended (expected, no such app installed): \(error)")
        }
        await session.stop()
    }
}
