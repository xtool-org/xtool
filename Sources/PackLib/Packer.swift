import Foundation
import XUtils
import Dependencies

public struct Packer: Sendable {
    public let buildSettings: BuildSettings
    public let plan: Plan

    @Dependency(\.productBuilder) private var productBuilder

    public init(buildSettings: BuildSettings, plan: Plan) {
        self.plan = plan
        self.buildSettings = buildSettings
    }

    public func pack() async throws -> URL {
        let artifacts = try await productBuilder.build(buildSettings, plan)
        return try await assemble(artifacts: artifacts)
    }

    /// Assembly consumes completed build artifacts and never compiles or signs.
    public func assemble(artifacts: BuildArtifacts) async throws -> URL {
        try ResourceDestination.validateComponent(plan.app.product, "Application name")
        let output = try TemporaryDirectory(name: "\(plan.app.product).app")
        let root = URL(fileURLWithPath: buildSettings.packagePath, isDirectory: true).standardizedFileURL
        let assembler = BundleAssembler(plan: plan, sourceDirectory: root)
        try assembler.assemble(artifacts: artifacts, at: output.url)
        let directory = root.appendingPathComponent("xtool", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(output.url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try output.persist(at: destination)
        return destination
    }
}
