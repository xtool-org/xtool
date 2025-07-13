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
        let xtoolDir: Path = "xtool"

        let projectDir: Path = xtoolDir + ".xtool-tmp"
        try? xtoolDir.delete()
        try projectDir.mkpath()

        let fromProjectToRoot = try Path(".").relativePath(from: projectDir)

        guard let deploymentTarget = Version(tolerant: plan.app.deploymentTarget) else {
            throw StringError("Could not parse deployment target '\(plan.app.deploymentTarget)'")
        }

        let emptyText = Data("""
        // leave this file empty
        """.utf8)

        let targets = try plan.allProducts.map { product in
            let productDir = projectDir + product.product
            try productDir.mkpath()

            let emptyFile = productDir + "empty.c"
            try emptyFile.write(emptyText)

            let infoPath = productDir + "Info.plist"

            var plist = product.infoPlist
            let families = (plist.removeValue(forKey: "UIDeviceFamily") as? [Int]) ?? [1, 2]
            plist["CFBundleExecutable"] = product.targetName
            plist["CFBundleName"] = product.targetName
            plist["CFBundleDisplayName"] = product.product

            let encodedPlist = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try infoPath.write(encodedPlist)

            var buildSettings: [String: Any] = [
                "PRODUCT_BUNDLE_IDENTIFIER": product.bundleID,
                "TARGETED_DEVICE_FAMILY": families.map { "\($0)" }.joined(separator: ","),
            ]

            if product.type == .appExtension {
                plist["APPLICATION_EXTENSION_API_ONLY"] = true
            }

            if let entitlementsPath = product.entitlementsPath {
                buildSettings["CODE_SIGN_ENTITLEMENTS"] = fromProjectToRoot + Path(entitlementsPath)
            }

            let additionalDependencies: [Dependency] = if product.type == .application {
                plan.extensions.map {
                    Dependency(
                        type: .target,
                        reference: $0.targetName,
                        embed: true,
                        codeSign: false,
                        copyPhase: .plugins
                    )
                }
            } else {
                []
            }
            return Target(
                name: product.targetName,
                type: product.type == .application ? .application : .appExtension,
                platform: .iOS,
                deploymentTarget: deploymentTarget,
                settings: Settings(buildSettings: buildSettings),
                sources: [
                    TargetSource(
                        path: try emptyFile.relativePath(from: projectDir).string,
                        buildPhase: .sources
                    ),
                ],
                dependencies: [
                    Dependency(
                        type: .package(products: [product.product]),
                        reference: "RootPackage"
                    ),
                ] + additionalDependencies,
                info: Plist(
                    path: try infoPath.relativePath(from: projectDir).string,
                    attributes: [:]
                )
            )
        }

        let project = Project(
            name: plan.app.targetName,
            targets: targets,
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
        let xcodeproj = projectDir + "\(plan.app.product).xcodeproj"
        let xcworkspace = xtoolDir + "\(plan.app.product).xcworkspace"
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
