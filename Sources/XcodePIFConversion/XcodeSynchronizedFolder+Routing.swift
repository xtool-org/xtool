import XcodeProjects

/// Picks the phase a synchronized folder member implicitly joins, the way Xcode routes a file added to a target.
///
/// Each file type declares the kinds of phase it can join (see ``XcodeFileType/implicitPhases``). Xcode first
/// tries the target's phases in order, skipping catch-all phases; then the first catch-all phase; then the
/// type's fallback phase, if the target has one. Otherwise the file joins no phase.
extension XcodeSynchronizedFolder {
    static func implicitPhase(
        for fileType: XcodeFileType, in target: XCSchema.CommonTargetProperties
    ) -> XCSchema.BuildPhase? {
        let ancestry = Array(fileType.ancestry)
        guard !ancestry.contains(where: \.isProjectReference) else { return nil }
        let phases = target.buildPhases
        func isCatchAll(_ index: Int) -> Bool {
            switch phases[index].kind {
            case .javaArchive: true
            // Copy Files only collects files when the target does nothing else but run scripts.
            case .copy: phases.indices.allSatisfy { $0 == index || phases[$0].kind == .script }
            default: false
            }
        }
        // Like Xcode's Resources phase, anything that no type claims is a resource.
        let kinds = fileType.inherited(\.implicitPhases) ?? [.resources]
        let restriction = sourcesRestrictions[target.productTypeID?.productTypeID ?? ""]
        func accepts(_ kind: XCSchema.BuildPhase.Kind) -> Bool {
            if kind == .sources, let restriction {
                return fileType.conforms(to: restriction)
            }
            return kinds.contains(kind)
        }
        for index in phases.indices where !isCatchAll(index) && accepts(phases[index].kind) {
            return phases[index]
        }
        if let index = phases.indices.first(where: isCatchAll) { return phases[index] }
        if ancestry.contains(where: \.fallsBackToResources) {
            return phases.first { $0.kind == .resources }
        }
        return nil
    }

    /// Product types whose Sources phase only compiles one type of file.
    private static let sourcesRestrictions: [String: XcodeFileType] = [
        "com.apple.product-type.metal-library": .sourcecodeMetal,
        "com.apple.product-type.instruments-package": .comAppleInstrumentsPackageDefinition,
    ]
}
