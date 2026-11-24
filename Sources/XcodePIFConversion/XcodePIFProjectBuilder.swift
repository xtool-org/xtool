import Foundation
import OrderedCollections
import XcodeProjects
import XPIF

struct XcodePIFProjectBuilder {
    let loaded: XcodeLoadedProject
    let packageProjects: [XPIF.Project]
    var project: XCSchema.Project { loaded.project }
    var phaseFiles: [XPIF.GUID: [XPIF.BuildFile]] = [:]
    var usedIDs: Set<XPIF.GUID>

    init(loaded: XcodeLoadedProject, packageProjects: [XPIF.Project] = []) {
        self.loaded = loaded
        self.packageProjects = packageProjects
        self.usedIDs = loaded.usedIDs
    }

    mutating func buildProject(in projects: OrderedDictionary<URL, XcodeLoadedProject>) throws -> XPIF.Project {
        // Resolve memberships after all referenced projects and their products have been loaded.
        for (referenceID, membership) in loaded.memberships {
            let ref: XPIF.BuildFile.Ref = if let targetID = loaded.products[referenceID] {
                .targetProduct(id: targetID)
            } else {
                .reference(id: referenceID)
            }
            try addMembership(membership, ref: ref, fallback: referenceID.value)
        }
        for (index, product) in project.importedProducts.enumerated() {
            let remote = try referencedProject(product.project, in: projects)
            guard let targetID = remote.products[remote.guid(product.productID)] else {
                throw ConversionError("Unknown product \(product.productID.rawValue) in \(remote.projectURL.path)")
            }
            for membership in product.buildFiles {
                try addMembership(membership, ref: .targetProduct(id: targetID), fallback: "IMPORTED:\(index)")
            }
        }
        let configurations = try buildConfigurations(
            project.configurations, settings: project.buildSettings, ownerID: loaded.projectID
        )
        var result = XPIF.Project(
            id: loaded.projectID, path: loaded.projectURL.path, projectDir: loaded.sourceRoot.path,
            name: loaded.projectURL.deletingPathExtension().lastPathComponent,
            mainGroup: loaded.mainGroup, buildConfigs: configurations,
            targets: try project.targets.map { try convertTarget($0, projects: projects) },
            developmentRegion: project.localizationInfo.development.rawValue
        )
        result.defaultConfigurationName = project.defaultConfigurationName.rawValue
        let discoveredRegions = loaded.references.compactMap { entry -> String? in
            guard case .file(let file) = entry.reference else { return nil }
            return file.regionVariantName
        }
        result.knownRegions = Set(project.localizationInfo.allLanguages.map(\.rawValue)).union(discoveredRegions).sorted()
        result.classPrefix = project.classPrefix ?? ""
        result.appPreferencesBuildSettings = .init()
        return result
    }

    mutating func addMembership(
        _ membership: XCSchema.ProjectBuildFile, ref: XPIF.BuildFile.Ref, fallback: String
    ) throws {
        let phaseID = try loaded.resolvePhase(membership.buildPhase)
        let buildID = try identifier(membership.objectID, fallback: "\(phaseID.value)::FILE:\(fallback)")
        phaseFiles[phaseID, default: []].append(Self.buildFile(id: buildID, ref: ref, properties: membership.properties))
    }

    mutating func identifier(_ objectID: XCSchema.ObjectID?, fallback: String) throws -> XPIF.GUID {
        let id = objectID.map(loaded.guid) ?? XPIF.GUID(fallback)
        guard objectID?.rawValue.isEmpty != true, !id.value.isEmpty, usedIDs.insert(id).inserted else {
            throw ConversionError("Empty or duplicate Xcode object identifier: \(id.value)")
        }
        return id
    }
}

extension XCSchema.BuildPhase {
    var properties: XCSchema.BuildPhaseProperties {
        switch self {
        case .frameworks(let properties), .headers(let properties), .javaArchive(let properties),
             .resources(let properties), .rez(let properties), .sources(let properties): properties
        case .appleScript(let properties): properties.baseProperties
        case .copy(let properties): properties.baseProperties
        case .script(let properties): properties.baseProperties
        }
    }
}
