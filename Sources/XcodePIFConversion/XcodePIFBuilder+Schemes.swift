import Foundation
import XcodeProjects
import XPIF

extension XcodePIFBuilder {
    public func scheme(named name: String) throws -> XcodeScheme {
        try XcodeScheme(named: name, containers: [workspaceURL] + projects.values.map(\.projectURL))
    }

    /// Resolve both the project and the target identifier: target names and IDs can repeat across projects.
    public func targetGUID(for reference: XcodeScheme.TargetReference) throws -> XPIF.GUID {
        guard let project = projects.values.first(where: { $0.projectURL.path == reference.projectURL.path }) else {
            throw ConversionError("Scheme references a project outside the workspace: \(reference.projectURL.path).")
        }
        let matches = project.project.targets.filter { target in
            if let objectID = reference.objectID, !objectID.isEmpty {
                return target.commonProperties.objectID.rawValue == objectID
            }
            return target.name == reference.name
        }
        guard matches.count == 1, let target = matches.first else {
            throw ConversionError("Could not resolve scheme target '\(reference.name)' in \(reference.projectURL.path).")
        }
        return project.guid(target.commonProperties.objectID)
    }
}
