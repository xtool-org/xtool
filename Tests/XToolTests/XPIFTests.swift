import Foundation
import Testing
import XPIF

struct XPIFTests {
    @Test func preservesXcodeFieldsWhenEditingAndResigning() throws {
        let fixture = fixtureURL("xcode-project.json")
        let original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [[String: Any]])
        var model = try XPIF.Container(data: JSONSerialization.data(withJSONObject: original))
        model.workspace.name = "Edited"
        let encoded = try model.data()
        let result = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        for object in original {
            let originalContents = try #require(object["contents"] as? [String: Any])
            let guid = try #require(originalContents["guid"] as? String)
            let output = try #require(result.first { ($0["contents"] as? [String: Any])?["guid"] as? String == guid })
            let contents = try #require(output["contents"] as? [String: Any])
            for (key, value) in originalContents where !["projects", "targets", "name"].contains(key) {
                try expectContains(jsonValue(contents[key]), original: jsonValue(value), path: "\(guid).\(key)")
            }
        }
        #expect(try XPIF.Container(data: encoded).data() == encoded)
    }

    @Test func constructsXcodeModelWithMetadataAndUnknownFields() throws {
        var config = XPIF.BuildConfig(id: "debug", name: "Debug", settings: .init())
        config.baseConfigurationFileReference = "xcconfig"
        config.settings[single: "CUSTOM_SETTING[sdk=iphoneos*][arch=arm64]"] = "value"
        config.additionalFields["futureConfigField"] = .array([.null, .bool(true)])
        var target = XPIF.Target(id: "target", productType: .appExtension, name: "Extension", productName: "Extension.appex")
        target.productReference.id = "actual-product-reference"
        target.productReference.additionalFields["futureProductField"] = .number(42)
        target.provisioningSourceData = [.init(
            configurationName: "Debug", provisioningStyle: .manual, bundleIdentifierFromInfoPlist: "com.example.extension"
        )]
        target.isPackageTarget = false
        target.classPrefix = "EX"
        target.predominantSourceCodeLanguage = "Xcode.SourceCodeLanguage.Swift"
        target.performanceTestsBaselinesPath = "Baselines"
        target.buildConfigs = [config]
        target.additionalFields["futureTargetField"] = .object(["data": .array([.number(1), .string("two")])])
        var project = XPIF.Project(id: "project", path: "/tmp/Project.xcodeproj", projectDir: "/tmp", name: "Project")
        project.targets = [.target(target)]
        project.buildConfigs = [config]
        project.defaultConfigurationName = "Debug"
        project.knownRegions = ["en", "Base"]
        project.classPrefix = "PR"
        project.appPreferencesBuildSettings = .init()
        project.appPreferencesBuildSettings?[single: "DEVELOPMENT_TEAM"] = "TEAM"
        project.additionalFields["futureProjectField"] = .bool(false)
        var workspace = XPIF.Workspace(id: "workspace", name: "Workspace", path: "/tmp", projects: [project])
        workspace.additionalFields["futureWorkspaceField"] = .string("kept")
        let decoded = try XPIF.Container(data: XPIF.Container(workspace: workspace).data())
        let decodedProject = decoded.workspace.projects[0]
        guard case .target(let decodedTarget) = decodedProject.targets[0] else {
            Issue.record("Expected a standard target")
            return
        }
        #expect(decodedTarget.productReference == target.productReference)
        #expect(decodedTarget.provisioningSourceData == target.provisioningSourceData)
        #expect(decodedTarget.classPrefix == "EX")
        #expect(decodedTarget.predominantSourceCodeLanguage == target.predominantSourceCodeLanguage)
        #expect(decodedTarget.performanceTestsBaselinesPath == "Baselines")
        #expect(decodedTarget.additionalFields == target.additionalFields)
        #expect(decodedProject.buildConfigs == project.buildConfigs)
        #expect(decodedProject.defaultConfigurationName == "Debug")
        #expect(decodedProject.knownRegions == ["en", "Base"])
        #expect(decodedProject.appPreferencesBuildSettings == project.appPreferencesBuildSettings)
        #expect(decodedProject.additionalFields == project.additionalFields)
        #expect(decoded.workspace.additionalFields == workspace.additionalFields)
    }

    @Test func roundTripsLocalizedAndVersionedGroups() throws {
        let data = Data("""
        {"guid":"root","type":"group","sourceTree":"<group>","futureField":7,"children":[
          {"guid":"localized","type":"variantGroup","name":"Main.storyboard","children":[
            {"guid":"en","type":"file","sourceTree":"SDKROOT","path":"en.lproj/Main.storyboard",
             "fileType":"file.storyboard","regionVariantName":"en","fileTextEncoding":"utf-8",
             "expectedSignature":"signature","futureFileField":true}
          ]},
          {"guid":"versions","type":"versionGroup","path":"Model.xcdatamodeld","children":[]}
        ]}
        """.utf8)
        var group = try JSONDecoder().decode(XPIF.Group.self, from: data)
        group.name = "Edited"
        let decoded = try roundTrip(group)
        #expect(decoded == group)
        guard case .group(let localized) = decoded.subitems[0], case .file(let file) = localized.subitems[0],
              case .group(let versions) = decoded.subitems[1] else {
            Issue.record("Expected localized and versioned groups")
            return
        }
        #expect(localized.kind == .variantGroup)
        #expect(versions.kind == .versionGroup)
        #expect(file.pathBase == .buildSetting("SDKROOT"))
        #expect(file.regionVariantName == "en")
        #expect(file.fileTextEncoding == "utf-8")
        #expect(file.expectedSignature == "signature")
        #expect(file.additionalFields["futureFileField"] == .bool(true))
    }

    @Test(arguments: ["fileReference", "targetReference", "named"])
    func roundTripsBuildFileAttributes(reference: String) throws {
        var object: [String: Any] = [
            "guid": "buildfile", "headerVisibility": "public", "intentsCodegenVisibility": "private",
            "resourceRule": "copy", "additionalCompilerOptions": ["-DTEST", "-Werror"],
            "codeSignOnCopy": "true", "removeHeadersOnCopy": "true", "shouldLinkWeakly": "true",
            "assetTags": ["tag"], "decompress": "true", "shouldWarnIfNoRuleToProcess": "false",
            "migCodegenFiles": "client", "futureField": ["value": true],
        ]
        if reference == "named" {
            object["name"] = "UIKit.framework"
            object["fileType"] = "wrapper.framework"
        } else {
            object[reference] = "reference"
        }
        let file = try JSONDecoder().decode(XPIF.BuildFile.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(file.headerVisibility == .public)
        #expect(file.codeSignOnCopy && file.removeHeadersOnCopy && file.shouldLinkWeakly)
        #expect(file.generatedCodeVisibility == .private)
        #expect(file.resourceRule == .copy)
        #expect(file.additionalCompilerOptions == .array(["-DTEST", "-Werror"]))
        #expect(file.assetTags == ["tag"])
        #expect(file.platformFilters.isEmpty)
        #expect(try roundTrip(file) == file)
    }

    @Test func roundTripsScriptFileListsAndDependencyInfo() throws {
        let data = Data("""
        {"guid":"script","type":"com.apple.buildphase.shell-script","name":"Generate",
         "scriptContents":"echo generated","inputFileListPaths":["Inputs.xcfilelist"],
         "outputFileListPaths":["Outputs.xcfilelist"],"dependencyFileFormat":"makefile",
         "dependencyFilePaths":["generated.d"],"futurePhaseField":[false,null]}
        """.utf8)
        let phase = try JSONDecoder().decode(XPIF.ShellScriptBuildPhase.self, from: data)
        #expect(phase.inputFileListPaths == ["Inputs.xcfilelist"])
        #expect(phase.outputFileListPaths == ["Outputs.xcfilelist"])
        #expect(phase.dependencyInfo == .makefile("generated.d"))
        #expect(phase.sandboxingOverride == .basedOnBuildSetting)
        #expect(try roundTrip(phase) == phase)
    }

    @Test func preservesArbitraryBuildSettingConditionsAndProductTypes() throws {
        let settings = Data("""
        {"OTHER_SWIFT_FLAGS[__platform_filter=ios;ios-simulator]":["$(inherited)"],
         "CUSTOM[sdk=iphoneos*][arch=arm64]":"value","PLUGIN_FLAGS":["one","two"]}
        """.utf8)
        let decoded = try JSONDecoder().decode(XPIF.BuildSettings.self, from: settings)
        #expect(try jsonValue(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)))
            == jsonValue(JSONSerialization.jsonObject(with: settings)))
        let type = XPIF.Target.ProductType(rawValue: "custom.plugin.product-type")
        #expect(try roundTrip(type) == type)
    }

    @Test func constructsAndDecodesExternalTarget() throws {
        var target = XPIF.ExternalTarget(id: "external", name: "External", toolPath: .string("/usr/bin/make"))
        target.arguments = .array(["all"])
        target.additionalFields["futureExternalField"] = .null
        let decoded = try roundTrip(XPIF.BaseTarget.external(target))
        #expect(decoded == .external(target))
    }

    @Test func changingTargetResignsItsProjectAndWorkspace() throws {
        let fixture = fixtureURL("xcode-project.json")
        var model = try XPIF.Container(data: Data(contentsOf: fixture))
        let original = try signatures(in: model)
        model.workspace.projects[0].targets[0].common.name = "Edited"
        let edited = try signatures(in: model)
        #expect(original.count == 3)
        #expect(zip(original, edited).allSatisfy { $0 != $1 })
        #expect(try signatures(in: model) == edited)
    }

    @Test func rejectsInvalidEnumAndDependencyData() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(XPIF.SandboxingOverride.self, from: Data("\"unknown\"".utf8))
        }
        let invalid = Data("""
        {"guid":"rule","name":"Rule","fileTypeIdentifier":"pattern.proxy","filePatterns":"*.in",
         "compilerSpecificationIdentifier":"com.apple.compilers.proxy.script","scriptContents":"echo",
         "inputFilePaths":[],"outputFilePaths":[],"dependencyFileFormat":"makefile","dependencyFilePaths":[]}
        """.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(XPIF.BuildRule.self, from: invalid) }
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func jsonValue(_ value: Any?) throws -> XPIF.JSONValue {
        try JSONDecoder().decode(XPIF.JSONValue.self, from: JSONSerialization.data(
            withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed]
        ))
    }

    private func signatures(in model: XPIF.Container) throws -> [String] {
        let objects = try #require(JSONSerialization.jsonObject(with: model.data()) as? [[String: Any]])
        return objects.compactMap { $0["signature"] as? String }
    }

    private func expectContains(_ result: XPIF.JSONValue, original: XPIF.JSONValue, path: String) throws {
        switch (result, original) {
        case (.object(let actual), .object(let expected)):
            for (key, value) in expected {
                let field = try #require(actual[key], "Missing field: \(path).\(key)")
                try expectContains(field, original: value, path: "\(path).\(key)")
            }
        case (.array(let actual), .array(let expected)):
            #expect(actual.count == expected.count)
            for (index, values) in zip(actual, expected).enumerated() {
                try expectContains(values.0, original: values.1, path: "\(path)[\(index)]")
            }
        default:
            #expect(result == original, "Changed field: \(path)")
        }
    }
}
