#if os(macOS)
import Foundation
import PathKit
import Version
import ProjectSpec
import XcodeGenKit
import XcodeProj

public struct XcodePacker {
    public var plan: Plan

    public init(plan: Plan) {
        self.plan = plan
    }

    // swiftlint:disable:next function_body_length
    public func createProject() async throws -> URL {
        let targetName = "\(plan.product)-App"

        let xtoolDir: Path = "xtool"

        let projectDir: Path = xtoolDir + ".xtool-tmp"
        try? xtoolDir.delete()
        try projectDir.mkpath()

        let infoPath = projectDir + "Info.plist"

        var plist = plan.infoPlist
        let families = (plist.removeValue(forKey: "UIDeviceFamily") as? [Int]) ?? [1, 2]
        plist["CFBundleExecutable"] = targetName
        plist["CFBundleName"] = targetName
        plist["CFBundleDisplayName"] = plan.product

        let encodedPlist = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try infoPath.write(encodedPlist)

        let emptyFile = projectDir + "empty.c"
        try emptyFile.write(Data("// leave this file empty".utf8))

        let fromProjectToRoot = try Path(".").relativePath(from: projectDir)

        guard let deploymentTarget = Version(tolerant: plan.deploymentTarget) else {
            throw StringError("Could not parse deployment target '\(plan.deploymentTarget)'")
        }

        var buildSettings: [String: Any] = [
            "PRODUCT_BUNDLE_IDENTIFIER": plan.bundleID,
            "TARGETED_DEVICE_FAMILY": families.map { "\($0)" }.joined(separator: ","),
        ]

        if let entitlementsPath = plan.entitlementsPath {
            buildSettings["CODE_SIGN_ENTITLEMENTS"] = fromProjectToRoot + Path(entitlementsPath)
        }

        let project = Project(
            name: plan.product,
            targets: [
                Target(
                    name: targetName,
                    type: .application,
                    platform: .iOS,
                    deploymentTarget: deploymentTarget,
                    settings: Settings(buildSettings: buildSettings),
                    sources: [
                        TargetSource(path: (fromProjectToRoot + emptyFile).string),
                    ],
                    dependencies: [
                        Dependency(
                            type: .package(products: [plan.product]),
                            reference: "RootPackage"
                        ),
                    ],
                    info: Plist(
                        path: (fromProjectToRoot + infoPath).string,
                        attributes: [:]
                    )
                )
            ],
            packages: [
                "RootPackage": .local(
                    path: fromProjectToRoot.string,
                    group: nil,
                    excludeFromProject: false
                ),
            ],
            options: SpecOptions(
                localPackagesGroup: ""
            )
        )

        // TODO: Handle plan.resources of type .root
        // TODO: Handle plan.iconPath

        let generator = ProjectGenerator(project: project)
        let xcodeproj = projectDir + "\(plan.product).xcodeproj"
        let xcworkspace = xtoolDir + "\(plan.product).xcworkspace"
        do {
            let current = Path.current
            Path.current = xcodeproj.parent()
            defer { Path.current = current }
            let xcodeProject = try generator.generateXcodeProject(userName: NSUserName())
            if let packageRef = xcodeProject.pbxproj.fileReferences.first(where: { $0.name == ".." }) {
                for group in xcodeProject.pbxproj.groups {
                    group.children.removeAll(where: { $0.uuid == packageRef.uuid })
                }
                xcodeProject.pbxproj.delete(object: packageRef)
            }

            if let emptyFileRef = xcodeProject.pbxproj.fileReferences.first(where: { $0.path == "empty.c" }),
               let existingGroup = xcodeProject.pbxproj.groups.first(where: {
                   $0.children.contains { $0.uuid == emptyFileRef.uuid }
               }),
               let existingGroupGroup = xcodeProject.pbxproj.groups.first(where: {
                   $0.children.contains { $0.uuid == existingGroup.uuid }
               }) {
                existingGroupGroup.children.removeAll(where: { $0.uuid == existingGroup.uuid })
                existingGroupGroup.children.insert(emptyFileRef, at: 0)
                xcodeProject.pbxproj.delete(object: existingGroup)
            }

            try xcodeProject.write(path: Path(xcodeproj.lastComponent))
        }

        do {
            let current = Path.current
            Path.current = xcworkspace.parent()
            defer { Path.current = current }

            let xcworkspaceDirectory = xcworkspace.parent()
            let fromWorkspaceToSelf = try Path(".").relativePath(from: xcworkspaceDirectory).withName()
            let fromWorkspaceToProject = try xcodeproj.relativePath(from: xcworkspaceDirectory).withName()
            let workspace = XCWorkspace(data: .init(children: [
                .file(.init(location: .container(fromWorkspaceToSelf.string))),
                .file(.init(location: .group(fromWorkspaceToProject.string))),
            ]))
            try workspace.write(path: Path(xcworkspace.lastComponent))
        }

        return xcworkspace.url
    }
}

extension Path {
    fileprivate func withName() -> Path {
        // eg if curr dir is Foo, this converts "." to "../Foo"
        // which includes the name in the path, and therefore
        // in the Xcode navigator
        self.parent() + self.absolute().lastComponent
    }
}

#endif
