import Foundation
import Supersign
import ArgumentParser

public enum SupersignCLI {
    public struct Configuration {
        public let superchargeApp: URL?
        public let storage: KeyValueStorage

        public init(
            superchargeApp: URL?,
            storage: KeyValueStorage
        ) {
            self.superchargeApp = superchargeApp
            self.storage = storage
        }
    }

    private static var _config: Configuration!
    static var config: Configuration { _config }

    public static func run(configuration: Configuration, arguments: [String]? = nil) throws {
        _config = configuration
        defer { defaultHTTPClientFactory.shutdown() }
        SupersignCommand.main(arguments)
    }
}

struct SupersignCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "supersign",
        abstract: "The Supersign command line tool",
        subcommands: [
            DSCommand.self,
            DevicesCommand.self,
            InstallCommand.self,
            UninstallCommand.self,
            SuperchargeCommand.self,
            RunCommand.self,
        ]
    )
}
