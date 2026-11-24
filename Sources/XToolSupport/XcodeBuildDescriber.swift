import XCLIUtils
import XPIF
import Foundation
import XcodeProjects
import XcodePIFConversion
import XUtils

struct XcodeBuildDescriber {
    let project: XToolProject.Xcode
    var scheme: String?

    func describe() async throws -> (pif: XPIF.Container, targetSelection: BuildDescription.TargetSelection?) {
        let container = project.container
        let builder: XcodePIFBuilder
        if container.pathExtension == "xcworkspace" {
            builder = try XcodePIFBuilder(workspace: XcodeWorkspace(url: container))
        } else {
            builder = try XcodePIFBuilder(project: XcodeProject(url: container))
        }
        let packages = try await XcodePackagePIFBuilder(
            builder: builder,
            rootDirectory: project.base.rootDirectory
        ).build()
        let workspace = try builder.build(packageProjects: packages)
        Signposter.track("Generated Xcode PIF")
        let pif = try describe(pif: XPIF.Container(workspace: workspace))
        var targetSelection: BuildDescription.TargetSelection?
        if let scheme {
            // TODO: swb: use bona fide scheme request
            let selection = try builder.scheme(named: scheme)
            var seen: Set<XPIF.GUID> = []
            let targets = try selection.buildTargets.map { try builder.targetGUID(for: $0) }
                .filter { seen.insert($0).inserted }
            guard !targets.isEmpty else { throw Console.Error("Scheme '\(scheme)' has no targets enabled for running.") }
            let runnable = try selection.runnable.map { try builder.targetGUID(for: $0) }
            let apps = workspace.projects.flatMap(\.targets).compactMap { base -> XPIF.Target? in
                guard case .target(let target) = base, target.productType == .application,
                      runnable.map({ $0 == target.id }) ?? targets.contains(target.id) else { return nil }
                return target
            }
            guard apps.count == 1, let app = apps.first else {
                throw Console.Error("Expected one application target in scheme '\(scheme)', found \(apps.count).")
            }
            // A runnable can be built indirectly by an aggregate target. Reject schemes
            // that would build other targets and then deploy an unrelated, stale app.
            let allTargets = Dictionary(uniqueKeysWithValues: workspace.projects.flatMap(\.targets).map { ($0.id, $0) })
            var pending = targets
            var reachable: Set<XPIF.GUID> = []
            while let target = pending.popLast() {
                guard reachable.insert(target).inserted else { continue }
                pending += allTargets[target]?.common.dependencies.map(\.targetId) ?? []
            }
            guard reachable.contains(app.id) else {
                throw Console.Error("Scheme '\(scheme)' does not build its runnable application for running.")
            }
            targetSelection = .init(
                application: app.id, buildTargets: targets, buildImplicitDependencies: selection.buildImplicitDependencies
            )
        }
        return (pif, targetSelection)
    }

    func describe(pif: XPIF.Container) throws -> XPIF.Container {
        var pif = pif
        #if !os(macOS)
        pif.workspace.projects = pif.workspace.projects.map { $0.withoutRelocatableLinkage() }
        #endif
        let projectIndex = try pif.workspace.projects.indices.first
            .orThrow(Console.Error("Xcode workspace contains no projects."))
        try pif.workspace.addUmbrellaTarget(toProjectAt: projectIndex)
        return pif
    }
}
