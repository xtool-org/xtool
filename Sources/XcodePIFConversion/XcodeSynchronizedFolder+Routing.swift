import XcodeProjects

/// Picks the phase a synchronized folder member implicitly joins, the way Xcode routes a file added to a target.
///
/// Each kind of phase accepts or rejects a type based on the most specific entry in its include/exclude lists
/// that matches the type or one of its ancestors. Xcode first tries the target's phases in order, skipping
/// catch-all phases; then the first catch-all phase; then the type's fallback phase, if the target has one.
/// Otherwise the file joins no phase.
extension XcodeSynchronizedFolder {
    static func implicitPhase(
        for fileType: String, in target: XCSchema.CommonTargetProperties
    ) -> XCSchema.BuildPhase? {
        let ancestry = XcodeFileType.ancestry(of: fileType)
        guard !ancestry.contains(where: projectWrapperTypes.contains) else { return nil }
        let phases = target.buildPhases
        func isCatchAll(_ index: Int) -> Bool {
            switch phases[index].kind {
            case .javaArchive: true
            // Copy Files only collects files when the target does nothing else but run scripts.
            case .copy: phases.indices.allSatisfy { $0 == index || phases[$0].kind == .script }
            default: false
            }
        }
        let sources = sourcesIncludes[target.productTypeID?.productTypeID ?? ""] ?? PhaseFilter.sources
        for index in phases.indices where !isCatchAll(index) {
            let filter: PhaseFilter? = switch phases[index].kind {
            case .sources: sources
            case .headers: .headers
            case .frameworks: .frameworks
            case .rez: .rez
            case .appleScript: .appleScript
            case .resources: .resources
            case .copy, .script, .javaArchive: nil
            }
            if filter?.accepts(ancestry) == true { return phases[index] }
        }
        if let index = phases.indices.first(where: isCatchAll) { return phases[index] }
        if ancestry.contains(where: resourcesFallbackTypes.contains) {
            return phases.first { $0.kind == .resources }
        }
        return nil
    }

    private static let projectWrapperTypes: Set = ["wrapper.pb-project", "file.swiftpm-manifest"]
    private static let resourcesFallbackTypes: Set = ["archive.rsrc", "archive.metal-library", "file.intentdefinition"]

    /// Product types that restrict what their Sources phase compiles.
    private static let sourcesIncludes: [String: PhaseFilter] = [
        "com.apple.product-type.metal-library": .init(includes: ["sourcecode.metal"], excludes: PhaseFilter.sources.excludes),
        "com.apple.product-type.instruments-package": .init(
            includes: ["com.apple.instruments.package-definition"], excludes: PhaseFilter.sources.excludes
        ),
    ]
}

private struct PhaseFilter {
    var includes: Set<String>
    var excludes: Set<String> = []
    var includesEverything = false

    func accepts(_ ancestry: [String]) -> Bool {
        for type in ancestry {
            if excludes.contains(type) { return false }
            if includes.contains(type) { return true }
        }
        return includesEverything
    }

    static let headers = Self(includes: ["sourcecode.c.h", "sourcecode.cpp.h", "text.apinotes"])
    static let rez = Self(includes: ["sourcecode.rez", "archive.rsrc"])
    static let appleScript = Self(includes: ["sourcecode.applescript", "sourcecode.scpt"])
    static let frameworks = Self(includes: [
        "wrapper.framework", "wrapper.xcframework", "archive.ar", "compiled.mach-o.dylib", "compiled.mach-o.objfile",
        "sourcecode.text-based-dylib-definition", "archive.jar", "archive.war", "archive.ear",
    ])
    static let sources = Self(
        includes: [
            "sourcecode", "text.xml.ibArchivingDescription", "text.xml.ibCodingDescription", "folder.mlpackage",
            "folder.documentationcatalog", "file.referenceobject", "folder.fmadapter", "folder.mlasset", "folder.aimodel",
        ],
        excludes: headers.includes.union(rez.includes).union([
            "sourcecode.scpt", "sourcecode.glsl", "sourcecode.javascript", "sourcecode.typescript",
            "net.daringfireball.markdown", "sourcecode.module-map", "sourcecode.text-based-dylib-definition",
        ])
    )
    /// Resources takes everything that no specific phase claims, bar a few types that belong nowhere.
    static let resources = Self(
        includes: ["sourcecode.glsl", "sourcecode.javascript", "net.daringfireball.markdown"],
        excludes: sources.includes.union(headers.includes).union(frameworks.includes).union(rez.includes)
            .union(appleScript.includes).union([
                "file.playground", "sourcecode.module-map", "sourcecode.text-based-dylib-definition",
                "text.plist.entitlements",
            ]),
        includesEverything: true
    )
}
