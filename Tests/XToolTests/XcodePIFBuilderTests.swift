import Foundation
import XcodeProjects
import XPIF
import Testing
@testable import XToolSupport
@testable import XcodePIFConversion

struct XcodePIFBuilderTests {
    let projectURL = URL(filePath: "/tmp/Probe.xcodeproj").resolvingSymlinksInPath()

    @Test func convertsPBXProjectAndProducesStablePIF() throws {
        let source = try fixtureProject()
        let workspace = try XcodePIFBuilder(project: source).build()
        let project = try #require(workspace.projects.first)
        #expect(project.id.value == "e199eb287a19a5a0c958424ee41fbfd2")
        #expect(project.name == "Probe")
        #expect(project.projectDir == projectURL.deletingLastPathComponent().path)
        #expect(project.defaultConfigurationName == "Debug")
        #expect(project.developmentRegion == "en")
        #expect(project.knownRegions == ["Base", "en"])
        guard case .target(let target) = try #require(project.targets.first) else {
            Issue.record("Expected a native target")
            return
        }
        let prefix = XcodeLoadedProject.digest("Probe.xcodeproj")
        #expect(target.id.value == prefix + XcodeLoadedProject.digest("78DE96411CD202404D0EB238"))
        #expect(target.productType == .application)
        #expect(target.productReference.id.value == prefix + XcodeLoadedProject.digest("670DC86C0DB18949CDB87DC1"))
        #expect(target.buildConfigs.map(\.name) == ["Debug", "Release"])
        #expect(target.buildConfigs.allSatisfy { $0.settings[.PRODUCT_NAME] == "CustomApp" })
        #expect(project.buildConfigs[0].settings[single: "SWIFT_OPTIMIZATION_LEVEL"] == "-Onone")
        #expect(project.buildConfigs[1].settings[single: "SWIFT_OPTIMIZATION_LEVEL"] == "-O")
        guard case .sources(let phase) = try #require(target.buildPhases.first) else {
            Issue.record("Expected a sources phase")
            return
        }
        #expect(phase.files.map(\.ref) == [.reference(id: project.mainGroup.subitems[0].id)])
        let data = try XPIF.Container(workspace: workspace).data()
        #expect(try XPIF.Container(data: data).data() == data)
        let jsonProject = try XcodeProject(
            project: .init(jsonRepresentation: source.project.jsonRepresentation()), url: projectURL, format: .xcproj
        )
        let jsonWorkspace = try XcodePIFBuilder(project: jsonProject).build()
        #expect(try XPIF.Container(workspace: jsonWorkspace).data() == data)
        #expect(try XPIF.Container(workspace: XcodePIFBuilder(project: source).build()).data() == data)
    }

    @Test(.requiresXcode) func generatedWorkspaceIsAcceptedByBuildService() async throws {
        let workspace = try XcodePIFBuilder(project: fixtureProject()).build()
        let description = try BuildDescription(
            directory: URL(filePath: "."),
            pif: XcodeBuildDescriber(project: .init(
                base: .init(rootDirectory: URL(filePath: "."), schema: .default), container: projectURL
            )).describe(pif: .init(workspace: workspace)),
            configuration: .debug,
            triple: "arm64-apple-ios-simulator"
        )
        let coordinator = try await BuildCoordinator(description: description)
        #expect(try await coordinator.mainProductDetails().output.lastPathComponent == "CustomApp.app")
        await coordinator.close()
    }

    @Test func mapsConfigurationConditionsAndXCConfigs() throws {
        var source = try fixtureProject()
        source.project.buildSettings = [
            "FLAGS": .array(["base"]),
            "FLAGS[config=Debug][sdk=iphoneos*]": .array(["$(inherited)", "device-debug"]),
            "FLAGS[config=Release]": .string("release"),
            "OTHER[config=Deb*]": .string("debug"),
            "ORDERED[config=Debug][sdk=iphoneos*]": .string("specific"),
            "ORDERED[sdk=iphoneos*][config=*]": .string("default"),
        ]
        source.project.topLevelReferences.append(.fileReference(.init(
            objectID: nil, path: "Settings.xcconfig", explicitFileType: nil, expectedSignature: nil,
            textEncoding: nil, lineEnding: nil, includeInIndex: nil, buildFiles: []
        )))
        source.project.configurations[0].file = .init(
            anchor: .namePath(.init(components: [.child("Settings.xcconfig")])), relativePath: nil
        )
        let result = try XcodePIFBuilder(project: source).build().projects[0]
        let debug = result.buildConfigs[0]
        let release = result.buildConfigs[1]
        #expect(debug.settings.values["FLAGS"] == .string("base"))
        #expect(debug.settings.values["FLAGS[sdk=iphoneos*]"] == .string("$(inherited) device-debug"))
        #expect(debug.settings[single: "OTHER"] == "debug")
        #expect(debug.settings[single: "ORDERED[sdk=iphoneos*]"] == "specific")
        #expect(release.settings[single: "ORDERED[sdk=iphoneos*]"] == "default")
        #expect(release.settings[single: "FLAGS"] == "release")
        #expect(release.settings.values["OTHER"] == nil)
        #expect(debug.baseConfigurationFileReference == result.mainGroup.subitems.last?.id)
        #expect(result.targets[0].common.buildConfigs[0].baseConfigurationFileReference == nil)
    }

    @Test(arguments: [
        ("Debug.+(QA)", "Debug.+(QA)", true),
        ("Debug.+(QA)", "DebugXYZQA", false),
        ("D?bug", "Débug", true),
        ("D?bug", "Debugging", false),
        ("*Release?", "MyRelease1", true),
        ("*Release?", "MyRelease12", false),
        ("*", "", true),
        ("", "Debug", false),
    ])
    func matchesConfigurationGlobs(pattern: String, configuration: String, applies: Bool) {
        let settings = XcodePIFProjectBuilder.buildSettings([
            "FLAGS[config=\(pattern)][sdk=iphoneos*][config=*]": .array(["flag"]),
        ], configuration: configuration)
        #expect(settings.values["FLAGS[sdk=iphoneos*]"] == (applies ? .string("flag") : nil))
        #expect(settings.values.count == (applies ? 1 : 0))
    }

    @Test func resolvesNamedPhasesLocalProductsAndBuildFileAttributes() throws {
        var source = try fixtureProject()
        var app = source.project.targets[0].commonProperties
        let frameworkID = XCSchema.ObjectID("FRAMEWORK")
        var framework = app
        framework.name = "Support"
        framework.objectID = frameworkID
        framework.specializedConfigurations = []
        framework.buildPhases = []
        framework.dependencies = []
        framework.product = .namePath(.init(components: [.child("Support.framework")]))
        framework.productTypeID = .init(rawValue: "com.apple.product-type.framework")
        app.dependencies = [.localTarget(.init(targetName: "Support"), [.init(rawValue: "maccatalyst")])]
        app.buildPhases.append(.frameworks(.init(objectID: nil, name: nil)))
        app.buildPhases.append(.copy(.init(
            objectID: nil, name: "Embed", bundleBasePath: .frameworksDir, relativePath: "", scope: .always
        )))
        source.project.targets = [.native(app), .native(framework)]
        let properties = XCSchema.BuildFileProperties(
            platformFilters: [.init(rawValue: "ios")], additionalBuildFlags: "-DTEST", assetTags: [.init(rawValue: "asset")],
            attributes: .init(headerRole: .public, machInterfaceGeneration: .client, isWeak: true, codeSignOnCopy: true,
                              codeGeneration: .skip, headerPreservation: .removeOnCopy, decompress: true,
                              codeGenerationVisibility: nil)
        )
        source.project.topLevelReferences.append(.fileReference(.init(
            objectID: nil, path: "<PRODUCTS>/Support.framework", explicitFileType: nil, expectedSignature: nil,
            textEncoding: nil, lineEnding: nil, includeInIndex: nil, buildFiles: [
                .init(objectID: nil, buildPhase: .named(target: .init(targetName: "Probe"), kind: .frameworks, name: nil),
                      properties: properties),
                .init(objectID: nil, buildPhase: .named(target: .init(targetName: "Probe"), kind: .copy, name: "Embed"),
                      properties: properties),
            ]
        )))
        let target = try XcodePIFBuilder(project: source).build().projects[0].targets[0]
        var dependency = XPIF.TargetDependency(
            targetId: .init(XcodeLoadedProject.digest("Probe.xcodeproj") + XcodeLoadedProject.digest("FRAMEWORK")),
            platformFilters: [.init(platform: "ios", environment: "maccatalyst")]
        )
        dependency.additionalFields["name"] = .string("Support")
        #expect(target.common.dependencies == [dependency])
        guard case .frameworks(let phase) = target.common.buildPhases[1],
              case .copyFiles(let copy) = target.common.buildPhases[2] else {
            Issue.record("Expected link and embed phases")
            return
        }
        let file = try #require(phase.files.first)
        #expect(file.ref == .targetProduct(id: dependency.targetId))
        #expect(file.headerVisibility == .public)
        #expect(file.generatedCodeVisibility == .noCodegen)
        #expect(file.platformFilters == [.init(platform: "ios")])
        #expect(file.additionalCompilerOptions == .string("-DTEST"))
        #expect(file.shouldLinkWeakly && file.codeSignOnCopy && file.removeHeadersOnCopy && file.decompress)
        #expect(file.assetTags == ["asset"])
        #expect(file.migCodegenFiles == "client")
        #expect(copy.destinationSubfolder == .frameworks)
        #expect(copy.files.first?.ref == file.ref)
    }

    @Test func convertsScriptsAndRules() throws {
        var source = try fixtureProject()
        var app = source.project.targets[0].commonProperties
        app.buildPhases.append(.script(.init(
            objectID: nil, name: "Generate", shellPath: "/bin/sh", script: "echo generated", logEnvironmentVariables: true,
            inputPaths: ["input"], inputFileListPaths: ["inputs.xcfilelist"], outputPaths: ["output"],
            outputFileListPaths: ["outputs.xcfilelist"], dependencyFile: "deps.d", runOnEveryBuild: true, scope: .install
        )))
        app.buildRules = [.init(
            objectID: nil, processor: "com.apple.compilers.proxy.script", name: "Rule", fileType: nil,
            filePatterns: "*.custom", script: "echo rule", inputFiles: ["in"], inputFileLists: [],
            outputFiles: ["out"], outputFileLists: [], outputFilesCompilerFlags: ["-DGENERATED"],
            dependencyFile: "rule.d", runOncePerArchitecture: true
        )]
        source.project.targets[0] = .native(app)
        let result = try XcodePIFBuilder(project: source).build()
        let target = result.projects[0].targets[0]
        guard case .shellScript(let script) = target.common.buildPhases[1] else {
            Issue.record("Expected a script phase")
            return
        }
        #expect(script.scriptContents == "echo generated")
        #expect(script.inputFileListPaths == ["inputs.xcfilelist"])
        #expect(script.outputFileListPaths == ["outputs.xcfilelist"])
        #expect(script.dependencyInfo == .makefile("deps.d"))
        #expect(script.alwaysOutOfDate && script.emitEnvironment && script.runOnlyForDeploymentPostprocessing)
        #expect(target.common.buildRules.first?.input == .filePattern("*.custom"))
        let decoded = try XPIF.Container(data: XPIF.Container(workspace: result).data())
        let decodedTarget = decoded.workspace.projects[0].targets[0]
        #expect(decodedTarget.common.buildPhases == target.common.buildPhases)
        #expect(decodedTarget.common.buildRules == target.common.buildRules)
    }

    @Test func convertsLocalizedResourcesAndFilePathBases() throws {
        var source = try fixtureProject()
        var app = source.project.targets[0].commonProperties
        app.buildPhases.append(.resources(.init(objectID: nil, name: nil)))
        source.project.targets[0] = .native(app)
        let properties = XCSchema.BuildFileProperties(
            platformFilters: [], additionalBuildFlags: nil, assetTags: [],
            attributes: .init(headerRole: nil, machInterfaceGeneration: nil, isWeak: false, codeSignOnCopy: false,
                              codeGeneration: .default, headerPreservation: .keep, decompress: false, codeGenerationVisibility: nil)
        )
        let child = XCSchema.FileReference(
            objectID: nil, path: "en.lproj/Main.strings", explicitFileType: nil, expectedSignature: "signature",
            textEncoding: .init(rawValue: .utf8), lineEnding: nil, includeInIndex: nil, buildFiles: []
        )
        source.project.topLevelReferences.append(.group(.init(
            objectID: nil, name: "Resources", path: "<PROJECT>/Resources", includeInIndex: nil,
            children: [.variantGroup(.init(
                objectID: nil, name: "Main.strings", path: "", includeInIndex: nil,
                buildFiles: [.init(objectID: nil,
                                   buildPhase: .named(target: .init(targetName: "Probe"), kind: .resources, name: nil),
                                   properties: properties)], children: [child]
            ))]
        )))
        let project = try XcodePIFBuilder(project: source).build().projects[0]
        guard case .group(let resources) = project.mainGroup.subitems[2],
              case .group(let variant) = resources.subitems[0], case .file(let file) = variant.subitems[0],
              case .copyBundleResources(let phase) = project.targets[0].common.buildPhases[1] else {
            Issue.record("Expected a localized resource group and phase")
            return
        }
        #expect(resources.pathBase == .projectDir)
        #expect(resources.path == "Resources")
        #expect(variant.kind == .variantGroup)
        #expect(file.pathBase == .groupDir)
        #expect(file.fileTextEncoding == "utf-8")
        #expect(file.regionVariantName == "en")
        #expect(file.expectedSignature == "signature")
        #expect(phase.files.first?.ref == .reference(id: variant.id))
    }

    @Test func convertsAggregateAndExternalTargets() throws {
        var source = try fixtureProject()
        var aggregate = source.project.targets[0].commonProperties
        aggregate.objectID = .init("AGGREGATE")
        aggregate.name = "All"
        aggregate.product = nil
        aggregate.productTypeID = nil
        aggregate.buildPhases = []
        aggregate.specializedConfigurations = []
        aggregate.dependencies = [.localTarget(.init(targetName: "Probe"), [])]
        var external = aggregate
        external.objectID = .init("EXTERNAL")
        external.name = "Tool"
        external.dependencies = []
        source.project.targets += [
            .aggregate(aggregate),
            .externalBuildSystem(.init(commonProperties: external, buildToolPath: "/usr/bin/make", buildToolArguments: "all",
                                       buildToolWorkingDirectory: nil, passBuildSettingsInEnvironment: false)),
        ]
        let project = try XcodePIFBuilder(project: source).build().projects[0]
        guard case .aggregate(let target) = project.targets[1], case .external(let tool) = project.targets[2] else {
            Issue.record("Expected aggregate and external targets")
            return
        }
        #expect(target.dependencies.first?.targetId == project.targets[0].id)
        #expect(target.buildConfigs.map(\.name) == ["Debug", "Release"])
        #expect(tool.toolPath == .string("/usr/bin/make"))
        #expect(tool.arguments == .string("all"))
        #expect(tool.workingDirectory == .string("$(PROJECT_DIR)"))
        #expect(!tool.passBuildSettingsInEnvironment)
    }

    @Test func rejectsUnresolvedAndAmbiguousMemberships() throws {
        var source = try fixtureProject()
        var app = source.project.targets[0].commonProperties
        app.buildPhases = []
        source.project.targets[0] = .native(app)
        #expect(throws: XcodePIFConversionError.self) { try XcodePIFBuilder(project: source).build() }
        app.buildPhases = [.sources(.init(objectID: .init("SAME"), name: nil)), .sources(.init(objectID: .init("SAME"), name: nil))]
        source.project.targets[0] = .native(app)
        #expect(throws: XcodePIFConversionError.self) { try XcodePIFBuilder(project: source).build() }
    }

    private func fixtureProject() throws -> XcodeProject {
        let url = fixtureURL("simple-xcode-project.pbxproj")
        return try XcodeProject(project: .init(pbxprojRepresentation: Data(contentsOf: url)), url: projectURL)
    }
}
