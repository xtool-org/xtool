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

    struct Xcode {
        let base: Base
        /// The `.xcworkspace` or `.xcodeproj` to build.
        let container: URL
    }

    case swiftPM(SwiftPM)
    case xcode(Xcode)

    var base: Base {
        switch self {
        case .swiftPM(let swiftPM):
            return swiftPM.base
        case .xcode(let xcode):
            return xcode.base
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
            case .xcode:
                defaultSchema = """
                version: 1
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
        triple: String,
        scheme: String? = nil
    ) async throws -> BuildDescription {
        let scheme = scheme ?? base.schema.scheme
        let pif: XPIF.Container
        var targetSelection: BuildDescription.TargetSelection?
        switch self {
        case .swiftPM(let swiftPM):
            guard scheme == nil else { throw Console.Error("Scheme selection requires an Xcode project or workspace.") }
            pif = try await SwiftPMBuildDescriber(project: swiftPM).describe()
        case .xcode(let xcode):
            (pif, targetSelection) = try await XcodeBuildDescriber(project: xcode, scheme: scheme).describe()
        }
        return BuildDescription(
            directory: base.rootDirectory,
            pif: pif,
            configuration: configuration,
            triple: triple,
            targetSelection: targetSelection,
        )
    }
}

extension XToolProject.Base {
    fileprivate func project() async throws -> XToolProject {
        if let path = schema.project {
            let directory = URL(fileURLWithPath: rootDirectory.path, isDirectory: true)
            let url = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Console.Error("xtool.yml: Could not find project '\(path)'.")
            }
            if url.lastPathComponent == "Package.swift" {
                return .swiftPM(.init(base: self, manifest: url))
            } else {
                return .xcode(.init(base: self, container: url))
            }
        }

        let contents = try FileManager.default.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)

        let workspaces = contents.filter { $0.pathExtension == "xcworkspace" }
        switch workspaces.count {
        case 0:
            break
        case 1:
            return .xcode(.init(base: self, container: workspaces[0]))
        default:
            throw Console.Error("Found multiple Xcode workspaces in this directory.")
        }

        let projects = contents.filter { $0.pathExtension == "xcodeproj" }
        switch projects.count {
        case 0:
            break
        case 1:
            return .xcode(.init(base: self, container: projects[0]))
        default:
            throw Console.Error("Found multiple Xcode projects in this directory.")
        }

        if let manifest = contents.first(where: {
            let name = $0.lastPathComponent
            return name == "Package.swift" || (name.hasPrefix("Package@") && name.hasSuffix(".swift"))
        }) {
            return .swiftPM(.init(base: self, manifest: manifest))
        }

        throw Console.Error("Could not find Package.swift, an Xcode workspace, or an Xcode project in this directory.")
    }
}
