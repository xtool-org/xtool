import Foundation
private import XcodeProj

/// The target selection of a scheme's Run action.
public struct XcodeScheme: Sendable {
    public struct TargetReference: Sendable {
        public let projectURL: URL
        public let objectID: String?
        public let name: String
        /// The product's filename, e.g. `App.app`.
        public let buildableName: String

        public init(projectURL: URL, objectID: String?, name: String, buildableName: String) {
            self.projectURL = projectURL
            self.objectID = objectID
            self.name = name
            self.buildableName = buildableName
        }
    }

    public let name: String
    public let buildTargets: [TargetReference]
    public let runnable: TargetReference?
    public let buildImplicitDependencies: Bool

    public init(
        name: String,
        buildTargets: [TargetReference],
        runnable: TargetReference?,
        buildImplicitDependencies: Bool = true,
    ) {
        self.name = name
        self.buildTargets = buildTargets
        self.runnable = runnable
        self.buildImplicitDependencies = buildImplicitDependencies
    }

    /// Finds shared schemes and the current user's schemes in the supplied containers.
    /// Duplicate names are rejected rather than selecting an arbitrary project.
    public init(named name: String, containers: [URL]) throws {
        guard !name.isEmpty, (name as NSString).lastPathComponent == name else {
            throw SchemeError("Invalid Xcode scheme name: '\(name)'.")
        }
        var matches: [(url: URL, container: URL)] = []
        var visited: Set<String> = []
        for container in containers {
            let container = container.standardizedFileURL.resolvingSymlinksInPath()
            guard visited.insert(container.path).inserted else { continue }
            let directories = [
                "xcuserdata/\(NSUserName()).xcuserdatad/xcschemes",
                "xcshareddata/xcschemes",
            ]
            for directory in directories {
                let url = container.appending(path: directory).appending(path: "\(name).xcscheme")
                if FileManager.default.fileExists(atPath: url.path) {
                    matches.append((url, container))
                }
            }
        }
        guard matches.count == 1, let match = matches.first else {
            if matches.isEmpty { throw SchemeError("Could not find Xcode scheme '\(name)'.") }
            throw SchemeError("Ambiguous Xcode scheme '\(name)': \(matches.map(\.url.path).joined(separator: ", ")).")
        }
        try self.init(url: match.url, container: match.container)
    }

    public init(url: URL, container: URL) throws {
        let scheme = try XCScheme(pathString: url.path)
        name = scheme.name
        let base = Self.referenceBase(for: container)
        func reference(_ reference: XCScheme.BuildableReference) throws -> TargetReference {
            let prefix = "container:"
            guard reference.referencedContainer.hasPrefix(prefix) else {
                throw SchemeError("Unsupported scheme container: \(reference.referencedContainer).")
            }
            let path = String(reference.referencedContainer.dropFirst(prefix.count))
            guard !path.isEmpty else { throw SchemeError("Empty project reference in scheme '\(scheme.name)'.") }
            let projectURL = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.resolvingSymlinksInPath()
            return TargetReference(
                projectURL: projectURL,
                objectID: reference.blueprintIdentifier,
                name: reference.blueprintName,
                buildableName: reference.buildableName,
            )
        }
        buildTargets = try (scheme.buildAction?.buildActionEntries ?? [])
            .filter { $0.buildFor.contains(.running) }
            .map { try reference($0.buildableReference) }
        buildImplicitDependencies = scheme.buildAction?.buildImplicitDependencies ?? true
        if let runnable = scheme.launchAction?.runnable {
            guard runnable is XCScheme.BuildableProductRunnable, let target = runnable.buildableReference else {
                throw SchemeError("Scheme '\(name)' does not launch a target product.")
            }
            self.runnable = try reference(target)
        } else {
            runnable = nil
        }
    }

    /// Writes the scheme into `container`, an `.xcodeproj` or `.xcworkspace`, either as a
    /// shared scheme or as one of the current user's schemes.
    public func write(in container: URL, shared: Bool) throws {
        let base = Self.referenceBase(for: container).resolvingSymlinksInPath()
        func reference(_ target: TargetReference) -> XCScheme.BuildableReference {
            XCScheme.BuildableReference(
                referencedContainer: "container:\(Self.path(of: target.projectURL, relativeTo: base))",
                blueprintIdentifier: target.objectID,
                buildableName: target.buildableName,
                blueprintName: target.name,
            )
        }
        let runnable = self.runnable.map { XCScheme.BuildableProductRunnable(buildableReference: reference($0)) }
        let scheme = XCScheme(
            name: name,
            lastUpgradeVersion: nil,
            version: "1.7",
            buildAction: XCScheme.BuildAction(
                buildActionEntries: buildTargets.map {
                    .init(
                        buildableReference: reference($0),
                        buildFor: [.running, .testing, .profiling, .archiving, .analyzing],
                    )
                },
                parallelizeBuild: true,
                buildImplicitDependencies: buildImplicitDependencies,
            ),
            testAction: XCScheme.TestAction(buildConfiguration: "Debug", macroExpansion: nil),
            launchAction: XCScheme.LaunchAction(runnable: runnable, buildConfiguration: "Debug"),
            profileAction: XCScheme.ProfileAction(runnable: runnable, buildConfiguration: "Release"),
            analyzeAction: XCScheme.AnalyzeAction(buildConfiguration: "Debug"),
            archiveAction: XCScheme.ArchiveAction(buildConfiguration: "Release", revealArchiveInOrganizer: true),
        )
        let directory = container.appending(
            path: shared ? "xcshareddata/xcschemes" : "xcuserdata/\(NSUserName()).xcuserdatad/xcschemes",
            directoryHint: .isDirectory,
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // dataRepresentation should never return nil
        try (scheme.dataRepresentation() ?? Data()).write(to: directory.appending(path: "\(name).xcscheme"))
    }

    /// The directory that a scheme's `container:` references are relative to.
    private static func referenceBase(for container: URL) -> URL {
        // References in a project's embedded workspace are relative to the project directory.
        let parent = container.deletingLastPathComponent()
        return parent.pathExtension == "xcodeproj" ? parent.deletingLastPathComponent() : parent
    }

    private static func path(of url: URL, relativeTo base: URL) -> String {
        let baseComponents = base.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let common = zip(baseComponents, components).prefix { $0 == $1 }.count
        let parents = Array(repeating: "..", count: baseComponents.count - common)
        return (parents + components.dropFirst(common)).joined(separator: "/")
    }

    public struct SchemeError: Error, CustomStringConvertible {
        public let description: String

        init(_ description: String) { self.description = description }
    }
}
