import Foundation
import XUtils
import XPIF

enum XToolProject {
    struct Base {
        let rootDirectory: URL
        let schema: PackSchema
    }

    struct SwiftPM {
        let base: Base
        let manifest: URL
    }

    case swiftPM(SwiftPM)

    var base: Base {
        switch self {
        case .swiftPM(let swiftPM):
            return swiftPM.base
        }
    }

    static func discover(start directory: URL) async throws -> XToolProject {
        // TODO: support running inside a child directory
        let configPath = directory.appendingPathComponent("xtool.yml")
        let hasSchema = FileManager.default.fileExists(atPath: configPath.path)

        let rootDirectory = configPath.deletingLastPathComponent()

        let schema: PackSchema = if hasSchema {
            try await PackSchema(url: configPath)
        } else {
            .default
        }
        let base = Base(rootDirectory: rootDirectory, schema: schema)
        let project = try await base.project()
        if !hasSchema {
            let defaultSchema: String
            switch project {
            case .swiftPM:
                d.out.print("""
                warning: Could not locate configuration file '\(configPath.path)'. Creating a default \
                configuration with 'com.example' organization ID.
                """)
                defaultSchema = """
                version: 1
                orgID: com.example
                """
            }
            try Data((defaultSchema + "\n").utf8).write(to: configPath)
        }
        return project
    }

    func tryEnsureLSPConfig(quiet: Bool = false) async {
        await LSPConfig.tryEnsure(using: base.schema, quiet: quiet, currentDirectory: base.rootDirectory)
    }

    func describe(
        configuration: BuildConfiguration,
        triple: String
    ) async throws -> BuildDescription {
        let pif: XPIF.Container
        switch self {
        case .swiftPM(let swiftPM):
            pif = try await SwiftPMBuildDescriber(project: swiftPM).describe()
        }
        return BuildDescription(
            directory: base.rootDirectory,
            pif: pif,
            configuration: configuration,
            triple: triple,
        )
    }
}

extension XToolProject.Base {
    fileprivate func project() async throws -> XToolProject {
        let contents = try FileManager.default.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)

        if let manifest = contents.first(where: {
            let name = $0.lastPathComponent
            return name == "Package.swift" || (name.hasPrefix("Package@") && name.hasSuffix(".swift"))
        }) {
            return .swiftPM(.init(base: self, manifest: manifest))
        }

        throw Console.Error("Could not find Package.swift in this directory.")
    }
}
