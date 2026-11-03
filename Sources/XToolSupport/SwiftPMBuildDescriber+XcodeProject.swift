import XCLIUtils
import Foundation
import Dependencies
import XcodeProjects
import XPIF
import XUtils

extension SwiftPMBuildDescriber {
    func writeXcodeProject() async throws -> ProjectBuildResult {
        try writeXcodeProject(basePIF: await d.swiftPMPIFDumper.dump(buildSettings: buildSettings))
    }

    // swiftlint:disable:next function_body_length
    func writeXcodeProject(basePIF pif: XPIF.Container) throws -> ProjectBuildResult {
        let root = URL(filePath: pif.workspace.path, directoryHint: .isDirectory)
        let mainProject = try pif.workspace.projects.first {
            $0.projectDir == pif.workspace.path && $0.id != "AGGREGATE"
        }.orThrow(Console.Error("Could not find main target"))
        let products = try bundleProducts(in: mainProject)
        let app = products[0]
        let extensions = Array(products.dropFirst())

        let xtoolDir = root.appendingPathComponent("xtool", isDirectory: true)
        let projectDir = xtoolDir.appendingPathComponent(".xtool-tmp", isDirectory: true)
        try? FileManager.default.removeItem(at: projectDir)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let fromProjectToRoot = "../.."

        let emptyText = Data("// leave this file empty".utf8)
        let targetIDs = products.map {
            XCSchema.ObjectID("xtool:\($0.product)")
        }
        let sourcePhase = XCSchema.BuildPhase.sources(.init(objectID: nil, name: nil))
        let frameworksPhase = XCSchema.BuildPhase.frameworks(.init(objectID: nil, name: nil))

        var groups: [XCSchema.Reference] = []
        var productFiles: [XCSchema.Reference] = []
        var targets: [XCSchema.Target] = []

        for (index, product) in products.enumerated() {
            let productDir = projectDir.appendingPathComponent(product.product, isDirectory: true)
            try FileManager.default.createDirectory(at: productDir, withIntermediateDirectories: true)
            try emptyText.write(to: productDir.appendingPathComponent("empty.c"))

            let (plist, plistSettings) = try product.infoPlistConfiguration(at: root)
            let encodedPlist = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try encodedPlist.write(to: productDir.appendingPathComponent("Info.plist"))

            var buildSettings: [String: XCSchema.BuildSetting] = plistSettings.values.mapValues { value in
                switch value {
                case .string(let value): .string(value)
                case .array(let value): .array(value)
                }
            }
            buildSettings["INFOPLIST_FILE"] = .string("\(product.product)/Info.plist")
            buildSettings["LD_RUNPATH_SEARCH_PATHS[sdk=iphone*]"] = .array(["$(inherited)", "@executable_path/Frameworks"])
            buildSettings["LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]"] = .array(["$(inherited)", "@executable_path/../Frameworks"])
            if product.isExtension {
                buildSettings["APPLICATION_EXTENSION_API_ONLY"] = .string("YES")
                buildSettings["LD_RUNPATH_SEARCH_PATHS[sdk=iphone*]"] = .array([
                    "$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks",
                ])
                buildSettings["LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]"] = .array([
                    "$(inherited)", "@executable_path/../Frameworks", "@executable_path/../../../../Frameworks",
                ])
            }
            if let entitlementsPath = product.entitlementsPath {
                let path = (entitlementsPath as NSString).isAbsolutePath
                    ? entitlementsPath
                    : (fromProjectToRoot as NSString).appendingPathComponent(entitlementsPath)
                buildSettings["CODE_SIGN_ENTITLEMENTS"] = .string(path)
            }

            let source = XCSchema.FileReference(
                objectID: nil,
                path: "empty.c",
                explicitFileType: nil,
                expectedSignature: nil,
                textEncoding: nil,
                lineEnding: nil,
                includeInIndex: nil,
                buildFiles: [.init(
                    objectID: nil,
                    buildPhase: .named(
                        target: .init(targetName: product.targetName),
                        kind: .sources,
                        name: nil
                    ),
                    properties: buildFileProperties(),
                )],
            )
            let info = XCSchema.FileReference(
                objectID: nil,
                path: "Info.plist",
                explicitFileType: nil,
                expectedSignature: nil,
                textEncoding: nil,
                lineEnding: nil,
                includeInIndex: nil,
                buildFiles: [],
            )
            let resources = try resourceReferences(for: product, at: root)
            groups.append(.group(.init(
                objectID: nil,
                name: product.product,
                path: try .init(base: .group, path: product.product),
                includeInIndex: nil,
                children: [.fileReference(source), .fileReference(info)] + resources,
            )))

            let productFilename = "\(product.product).\(product.isExtension ? "appex" : "app")"
            let productFile = XCSchema.FileReference(
                objectID: nil,
                path: try .init(base: .buildProducts, path: productFilename),
                explicitFileType: .init(fileTypeID: product.isExtension ? "wrapper.app-extension" : "wrapper.application"),
                expectedSignature: nil,
                textEncoding: nil,
                lineEnding: nil,
                includeInIndex: false,
                buildFiles: index == 0 ? [] : [.init(
                    objectID: nil,
                    buildPhase: .named(
                        target: .init(targetName: app.targetName),
                        kind: .copy,
                        name: "Embed App Extensions",
                    ),
                    properties: buildFileProperties(removeHeadersOnCopy: true),
                )],
            )
            productFiles.append(.fileReference(productFile))

            let packageProduct = XCSchema.SwiftPackageProductReference(
                objectID: nil,
                package: nil,
                productName: product.product,
                productType: .other,
            )
            let packageMember = XCSchema.SwiftPackageProductTargetMember(
                packageProduct: packageProduct,
                buildFile: .init(
                    objectID: nil,
                    buildPhase: .named(kind: .frameworks, name: nil),
                    properties: buildFileProperties(),
                ),
            )
            var phases = [sourcePhase, frameworksPhase]
            if !resources.isEmpty {
                phases.append(.copy(.init(
                    objectID: nil,
                    name: "Copy Root Resources",
                    bundleBasePath: .resourcesDir,
                    relativePath: "",
                    scope: .always,
                )))
            }
            if index == 0 && !extensions.isEmpty {
                phases.append(.copy(.init(
                    objectID: nil,
                    name: "Embed App Extensions",
                    bundleBasePath: .plugInsDir,
                    relativePath: "",
                    scope: .always,
                )))
            }
            let dependencies: [XCSchema.TargetDependency] = index == 0
                ? extensions.map {
                    .localTarget(XCSchema.LocalTargetReference(targetName: $0.targetName), [])
                }
                : []
            targets.append(.native(XCSchema.CommonTargetProperties(
                name: product.targetName,
                objectID: targetIDs[index],
                configurationListDebugID: nil,
                dependencies: dependencies,
                buildPhases: phases,
                buildRules: [],
                specializedConfigurations: [],
                buildSettings: buildSettings,
                product: .namePath(.init(components: [.child("Products"), .child(productFilename)])),
                productTypeID: XCSchema.ProductTypeID(
                    abbreviatedRepresentation: product.isExtension
                    ? "app-extension"
                    : "application"
                ),
                testHostTarget: nil,
                legacyProvisioningStyle: nil,
                legacyTeamID: nil,
                lastSwiftUpdateCheck: nil,
                lastSwiftMigration: nil,
                packageProductTargetMembers: [packageMember],
            )))
        }

        let schema = XCSchema.Project(
            objectID: nil,
            rootGroupDebugID: nil,
            configurationListDebugID: nil,
            topLevelReferences: groups + [
                .group(XCSchema.Group(
                    objectID: nil,
                    name: "Products",
                    path: "",
                    includeInIndex: nil,
                    children: productFiles,
                ))
            ],
            packages: [.init(location: .local(.init(path: fromProjectToRoot)), traits: [])],
            configurations: ["Debug", "Release"].map {
                .init(name: .init(name: $0), file: nil, objectID: nil)
            },
            buildSettings: projectBuildSettings(from: mainProject),
            defaultConfigurationName: .init(name: "Debug"),
            targets: targets,
            localizationInfo: .init(development: .init(languageID: "en"), supported: []),
            requiredCapabilities: [],
            buildIndependentTargetsInParallel: true,
            lastUpgradeCheck: nil,
            lastSwiftUpdateCheck: nil,
            lastSwiftMigration: nil,
            organizationName: nil,
            classPrefix: nil,
            productsGroup: .namePath(.init(components: [.child("Products")])),
            importedProducts: [],
        )

        let projectURL = projectDir.appending(path: "\(app.product).xcodeproj")
        let project = XcodeProject(project: schema, url: projectURL)
        try project.write()

        let workspaceURL = xtoolDir.appending(path: "\(app.product).xcworkspace")
        let workspace = XcodeWorkspace(children: [
            .file(XcodeWorkspace.Location(base: .container, path: "..")),
            .file(XcodeWorkspace.Location(base: .group, path: ".xtool-tmp/\(projectURL.lastPathComponent)"))
        ], url: workspaceURL)
        try workspace.write()
        return ProjectBuildResult(url: workspaceURL, bundleID: app.bundleID)
    }

    private func projectBuildSettings(from project: XPIF.Project) -> [String: XCSchema.BuildSetting] {
        var settings: [String: XCSchema.BuildSetting] = [
            "SDKROOT": .string("auto"),
            "SDK_VARIANT": .string("auto"),
            "SUPPORTED_PLATFORMS": .array(Self.supportedPlatforms),
        ]
        // Preserve each configuration's platform minimums without copying SwiftPM's
        // package-specific compiler and linker settings onto the app and extensions.
        for configuration in project.buildConfigs {
            for (key, value) in configuration.settings.values {
                let name = key.prefix { $0 != "[" }
                guard name.hasSuffix("_DEPLOYMENT_TARGET"),
                      case .string(let value) = value else { continue }
                settings["\(key)[config=\(configuration.name)]"] = .string(value)
            }
        }
        return settings
    }

    private func resourceReferences(for product: ProjectProduct, at root: URL) throws -> [XCSchema.Reference] {
        var paths = product.resources
        if let iconPath = product.iconPath {
            paths.append(iconPath)
        }

        var visited: Set<String> = []
        return try paths.compactMap { path in
            let url = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
            guard visited.insert(url.path).inserted else { return nil }
            let isAbsolute = (path as NSString).isAbsolutePath
            let referencePath = isAbsolute ? path : ("../.." as NSString).appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

            return .fileReference(.init(
                objectID: nil,
                path: try .init(base: isAbsolute ? .absolute : .project, path: referencePath),
                explicitFileType: isDirectory.boolValue ? .init(fileTypeID: "folder") : nil,
                expectedSignature: nil,
                textEncoding: nil,
                lineEnding: nil,
                includeInIndex: nil,
                buildFiles: [.init(
                    objectID: nil,
                    buildPhase: .named(
                        target: .init(targetName: product.targetName),
                        kind: .copy,
                        name: "Copy Root Resources",
                    ),
                    properties: buildFileProperties(),
                )],
            ))
        }
    }

    private func buildFileProperties(removeHeadersOnCopy: Bool = false) -> XCSchema.BuildFileProperties {
        XCSchema.BuildFileProperties(
            platformFilters: [],
            additionalBuildFlags: nil,
            assetTags: [],
            attributes: XCSchema.BuildFileAttributes(
                headerRole: nil,
                machInterfaceGeneration: nil,
                isWeak: false,
                codeSignOnCopy: false,
                codeGeneration: .default,
                headerPreservation: removeHeadersOnCopy ? .removeOnCopy : .keep,
                decompress: false,
                codeGenerationVisibility: nil,
            ),
        )
    }
}
