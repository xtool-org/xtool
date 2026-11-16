import XcodeProjects

extension XcodeSynchronizedFolder {
    func buildFiles(for members: [XCSchema.FolderMemberID], fileType: String) throws -> [XCSchema.ProjectBuildFile] {
        var result = project.targets.compactMap { target in
            buildFile(for: target.commonProperties, members: members, fileType: fileType)
        }
        for exception in folder.membershipExceptions {
            guard case .buildPhase(let exception) = exception,
                  members.contains(where: exception.commonProperties.membershipExceptions.contains) else { continue }
            let phase = try resolvePhase(exception.buildPhase)
            if let index = result.firstIndex(where: { $0.buildPhase == phase }) {
                Self.apply(exception.commonProperties, members: members, to: &result[index].properties)
            } else {
                var properties = Self.defaultProperties
                Self.apply(exception.commonProperties, members: members, to: &properties)
                result.append(.init(objectID: nil, buildPhase: phase, properties: properties))
            }
        }
        for index in result.indices {
            if case .objectID(let phase) = result[index].buildPhase, let path = members.first?.value {
                result[index].objectID = .init("\(identifierPrefix)::SYNCHRONIZED:BUILD:\(phase.rawValue):\(path)")
            }
        }
        return result
    }

    private func buildFile(
        for target: XCSchema.CommonTargetProperties, members: [XCSchema.FolderMemberID], fileType: String
    ) -> XCSchema.ProjectBuildFile? {
        let targetReference = XCSchema.LocalTargetReference(targetName: target.name)
        var includedMembers = folder.targets.contains(targetReference) ? Set(members) : []
        var properties = Self.defaultProperties
        for exception in folder.membershipExceptions {
            guard case .target(let exception) = exception, exception.target == targetReference else { continue }
            let common = exception.commonProperties
            let selected = Set(members).intersection(common.membershipExceptions)
            switch common.sense {
            case .inclusions: includedMembers.formUnion(selected)
            case .exclusions: includedMembers.subtract(selected)
            }
            Self.apply(common, members: members, to: &properties)
            for member in members {
                if exception.publicHeaders.contains(member) { properties.attributes.headerRole = .public }
                if exception.privateHeaders.contains(member) { properties.attributes.headerRole = .private }
                if let flags = exception.additionalCompilerFlags[member] { properties.additionalBuildFlags = flags }
            }
        }
        // A localized resource is a single build input as long as any variant belongs to the target.
        guard !includedMembers.isEmpty else { return nil }
        guard let phase = Self.implicitPhase(for: fileType, in: target) else { return nil }
        return .init(objectID: nil, buildPhase: Self.reference(to: phase, target: target.name), properties: properties)
    }

    func resolvePhase(_ reference: XCSchema.ProjectBuildPhaseReference) throws -> XCSchema.ProjectBuildPhaseReference {
        let matches = project.targets.flatMap { target in
            target.commonProperties.buildPhases.compactMap { phase -> XCSchema.ProjectBuildPhaseReference? in
                let matches: Bool = switch reference {
                case .objectID(let id): phase.properties.objectID == id
                case .named(let owner, let kind, let name):
                    target.name == owner.targetName && phase.kind == kind && phase.properties.name == name
                }
                return matches ? Self.reference(to: phase, target: target.name) : nil
            }
        }
        guard matches.count == 1, let match = matches.first else {
            throw ConversionError("Missing or ambiguous synchronized folder build phase: \(reference)")
        }
        return match
    }

    private static func reference(to phase: XCSchema.BuildPhase, target: String) -> XCSchema.ProjectBuildPhaseReference {
        if let id = phase.properties.objectID { return .objectID(id) }
        return .named(target: .init(targetName: target), kind: phase.kind, name: phase.properties.name)
    }

    private static func apply(
        _ common: XCSchema.CommonExceptionSetProperties, members: [XCSchema.FolderMemberID],
        to properties: inout XCSchema.BuildFileProperties
    ) {
        for member in members {
            if let filters = common.platformFiltersByFolderMemberID[member] { properties.platformFilters = filters }
            if let attributes = common.attributesByFolderMemberID[member] { properties.attributes = attributes }
            if let tags = common.assetTagsByFolderMemberID[member] { properties.assetTags = tags }
        }
    }

    private static var defaultProperties: XCSchema.BuildFileProperties {
        .init(platformFilters: [], additionalBuildFlags: nil, assetTags: [], attributes: .init(
            headerRole: nil, machInterfaceGeneration: nil, isWeak: false, codeSignOnCopy: false, codeGeneration: .default,
            headerPreservation: .keep, decompress: false, codeGenerationVisibility: nil
        ))
    }
}
