import Foundation
import Crypto
import XcodeProjects
import XPIF

/// Loaded project metadata, before resolving remote projects.
struct XcodeLoadedProject {
    let xcodeProject: XcodeProject
    let projectURL: URL
    let identifierPrefix: String
    let mainGroup: XPIF.Group
    let references: [ReferenceEntry]
    let memberships: [(XPIF.GUID, XCSchema.ProjectBuildFile)]
    let products: [XPIF.GUID: XPIF.GUID]
    let usedIDs: Set<XPIF.GUID>

    var sourceRoot: URL { xcodeProject.sourceRoot }
    var project: XCSchema.Project { xcodeProject.project }
    var projectID: XPIF.GUID {
        .init(identifierPrefix)
    }

    struct ReferenceEntry {
        let names: [String]
        let reference: XPIF.Reference
        let url: URL?
    }

    init(xcodeProject: XcodeProject, projectURL: URL, baseURL: URL) throws {
        let source = baseURL.pathComponents
        let destination = projectURL.pathComponents
        let shared = zip(source, destination).prefix { $0 == $1 }.count
        let relative = Array(repeating: "..", count: source.count - shared) + destination.dropFirst(shared)
        var loader = Loader(xcodeProject: xcodeProject, projectURL: projectURL,
                            identifierPrefix: Self.digest(relative.joined(separator: "/")))
        self = try loader.load()
    }

    private init(loader: Loader, mainGroup: XPIF.Group) {
        self.xcodeProject = loader.xcodeProject
        self.projectURL = loader.projectURL
        self.identifierPrefix = loader.identifierPrefix
        self.mainGroup = mainGroup
        self.references = loader.references
        self.memberships = loader.memberships
        self.products = loader.products
        self.usedIDs = loader.usedIDs
    }

    func guid(_ objectID: XCSchema.ObjectID) -> XPIF.GUID {
        Self.guid(objectID, prefix: identifierPrefix)
    }

    static func digest(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func guid(_ objectID: XCSchema.ObjectID, prefix: String) -> XPIF.GUID {
        if let discovered = XcodeSynchronizedFolder.pifGUID(objectID, projectPrefix: prefix) {
            return discovered
        }
        return .init(prefix + digest(objectID.rawValue))
    }

    func resolve(_ ref: XCSchema.GroupTreeReference) throws -> XPIF.Reference {
        try Self.resolve(ref, references: references, identifierPrefix: identifierPrefix)
    }

    func resolve(_ ref: XCSchema.GroupTreeAnchoredReference) throws -> XPIF.Reference {
        let anchor = try resolve(ref.anchor)
        guard let relativePath = ref.relativePath else { return anchor }
        guard var url = references.first(where: { $0.reference.id == anchor.id })?.url else {
            throw ConversionError("Cannot resolve Xcode configuration reference: \(ref)")
        }
        for component in relativePath.components {
            switch component {
            case .child(let name): url.append(path: name)
            case .relative(.current): break
            case .relative(.parent): url.deleteLastPathComponent()
            }
        }
        let matches = references.filter { $0.url?.standardizedFileURL == url.standardizedFileURL }
        guard matches.count == 1, let match = matches.first else {
            throw ConversionError("Missing or ambiguous Xcode configuration reference: \(ref)")
        }
        return match.reference
    }

    private static func resolve(
        _ ref: XCSchema.GroupTreeReference, references: [ReferenceEntry], identifierPrefix: String
    ) throws -> XPIF.Reference {
        let matches: [ReferenceEntry]
        switch ref {
        case .objectID(let id): matches = references.filter { $0.reference.id == guid(id, prefix: identifierPrefix) }
        case .namePath(let path):
            var names: [String] = []
            for component in path.components {
                switch component {
                case .child(let name): names.append(name)
                case .relative(.current): break
                case .relative(.parent):
                    guard !names.isEmpty else { throw ConversionError("Reference escapes the project group: \(ref)") }
                    names.removeLast()
                }
            }
            matches = references.filter { $0.names == names }
        }
        guard matches.count == 1, let match = matches.first else {
            throw ConversionError("Missing or ambiguous Xcode file reference: \(ref)")
        }
        return match.reference
    }

    func resolveTarget(_ name: String) throws -> XCSchema.CommonTargetProperties {
        guard let target = project.targets.first(where: { $0.name == name }) else {
            throw ConversionError("Unknown Xcode target: \(name)")
        }
        return target.commonProperties
    }

    func phaseID(_ phase: XCSchema.BuildPhase, target: XCSchema.CommonTargetProperties, index: Int) -> XPIF.GUID {
        phase.properties.objectID.map(guid) ?? .init("\(guid(target.objectID).value)::PHASE:\(index)")
    }

    func resolvePhase(_ ref: XCSchema.ProjectBuildPhaseReference) throws -> XPIF.GUID {
        var matches: [XPIF.GUID] = []
        for target in project.targets {
            for (index, phase) in target.commonProperties.buildPhases.enumerated() {
                let matchesReference: Bool
                switch ref {
                case .objectID(let id): matchesReference = phase.properties.objectID == id
                case .named(let targetRef, let kind, let name):
                    matchesReference = target.name == targetRef.targetName && phase.kind == kind && phase.properties.name == name
                }
                if matchesReference { matches.append(phaseID(phase, target: target.commonProperties, index: index)) }
            }
        }
        guard matches.count == 1, let match = matches.first else {
            throw ConversionError("Missing or ambiguous Xcode build phase: \(ref)")
        }
        return match
    }

    struct Loader {
        let xcodeProject: XcodeProject
        let projectURL: URL
        let identifierPrefix: String
        var sourceRoot: URL { xcodeProject.sourceRoot }
        var project: XCSchema.Project { xcodeProject.project }
        var references: [ReferenceEntry] = []
        var memberships: [(XPIF.GUID, XCSchema.ProjectBuildFile)] = []
        var products: [XPIF.GUID: XPIF.GUID] = [:]
        var usedIDs: Set<XPIF.GUID> = []

        var projectID: XPIF.GUID {
            .init(identifierPrefix)
        }

        mutating func load() throws -> XcodeLoadedProject {
            let targetNames = project.targets.map(\.name)
            guard targetNames.allSatisfy({ !$0.isEmpty }), Set(targetNames).count == targetNames.count else {
                throw ConversionError("Xcode project contains empty or duplicate target names.")
            }
            let name = projectURL.deletingPathExtension().lastPathComponent
            guard !name.isEmpty, project.configurations.contains(where: { $0.name == project.defaultConfigurationName }) else {
                throw ConversionError("Xcode project must have a name and a valid default build configuration.")
            }
            _ = try identifier(project.objectID, fallback: projectID.value)
            let rootID = try identifier(project.rootGroupDebugID, fallback: "\(projectID.value)::MAINGROUP")
            let children = try convertReferences(project.topLevelReferences, parentID: rootID, names: [], directory: sourceRoot)
            var mainGroup = XPIF.Group(id: rootID, path: "", pathBase: .groupDir, name: name, subitems: children)
            references.append(.init(names: [], reference: .group(mainGroup), url: sourceRoot))
            for target in project.targets {
                _ = try identifier(target.commonProperties.objectID, fallback: "")
                if let product = target.commonProperties.product {
                    let ref = try resolve(product)
                    guard case .file = ref else { throw ConversionError("Target product must be a file: \(product)") }
                    guard products.updateValue(guid(target.commonProperties.objectID), forKey: ref.id) == nil else {
                        throw ConversionError("Multiple targets use the same product reference: \(product)")
                    }
                }
            }
            // PIF registers product references on their targets. Including the same references
            // in the group tree would register their GUIDs twice.
            mainGroup = removingProducts(from: mainGroup)
            return XcodeLoadedProject(loader: self, mainGroup: mainGroup)
        }

        func guid(_ objectID: XCSchema.ObjectID) -> XPIF.GUID {
            XcodeLoadedProject.guid(objectID, prefix: identifierPrefix)
        }

        func resolve(_ ref: XCSchema.GroupTreeReference) throws -> XPIF.Reference {
            try XcodeLoadedProject.resolve(ref, references: references, identifierPrefix: identifierPrefix)
        }

        func removingProducts(from group: XPIF.Group) -> XPIF.Group {
            var result = group
            result.subitems = group.subitems.compactMap { reference in
                switch reference {
                case .file(let file): products[file.id] == nil ? reference : nil
                case .group(let child): .group(removingProducts(from: child))
                }
            }
            return result
        }

        mutating func identifier(_ objectID: XCSchema.ObjectID?, fallback: String) throws -> XPIF.GUID {
            let id = objectID.map(guid) ?? XPIF.GUID(fallback)
            guard objectID?.rawValue.isEmpty != true, !id.value.isEmpty, usedIDs.insert(id).inserted else {
                throw ConversionError("Empty or duplicate Xcode object identifier: \(id.value)")
            }
            return id
        }
    }
}
