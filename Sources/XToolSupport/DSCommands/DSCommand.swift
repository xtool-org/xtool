import Foundation
import XKit
import ArgumentParser
import Dependencies

struct DSAnisetteCommand: AsyncParsableCommand {
    private final class Provider: RawADIProvider, RawADIProvisioningSession {
        func startProvisioning(spim: Data, userID: UUID) async throws -> (RawADIProvisioningSession, Data) {
            print("spim: \(spim.base64EncodedString())")
            return (self, Data(base64Encoded: try await Console.prompt("cpim: "))!)
        }

        func endProvisioning(
            routingInfo: UInt64,
            ptm: Data,
            tk: Data
        ) async throws -> Data {
            print("""
            rinfo: \(routingInfo)
            ptm: \(ptm.base64EncodedString())
            tk: \(tk.base64EncodedString())
            """)
            return Data(base64Encoded: try await Console.prompt("pinfo: "))!
        }

        func requestOTP(
            userID: UUID,
            routingInfo: inout UInt64,
            provisioningInfo: Data
        ) -> (machineID: Data, otp: Data) {
            print("otp; pinfo: \(provisioningInfo)")
            return (Data(), Data())
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "anisette",
        abstract: "Test out Anisette data"
    )

    func run() async throws {
        let provider = withDependencies {
            $0.rawADIProvider = Provider()
        } operation: {
            ADIDataProvider()
        }
        let res = try await provider.fetchAnisetteData()
        print(res)
    }
}

struct DSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ds",
        abstract: "Interact with Apple Developer Services",
        subcommands: [
            DSTeamsCommand.self,
            DSCertificatesCommand.self,
            DSIdentifiersCommand.self,
            DSDevicesCommand.self,
            DSProfilesCommand.self,
            DSAnisetteCommand.self,
        ]
    )
}
