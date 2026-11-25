import Foundation
import OrderedCollections
import RegexBuilder
import XcodeProjects
import XPIF

extension XcodePIFProjectBuilder {
    mutating func buildConfigurations(
        _ configurations: [XCSchema.Configuration], settings: [String: XCSchema.BuildSetting], ownerID: XPIF.GUID
    ) throws -> [XPIF.BuildConfig] {
        guard !configurations.isEmpty, Set(configurations.map(\.name)).count == configurations.count else {
            throw ConversionError("Xcode project must have distinct, nonempty build configurations.")
        }
        return try configurations.map { configuration in
            let name = configuration.name.rawValue
            guard !name.isEmpty else { throw ConversionError("Empty Xcode build configuration name.") }
            let id = try identifier(configuration.objectID, fallback: "\(ownerID.value)::CONFIG:\(name)")
            var result = XPIF.BuildConfig(id: id, name: name, settings: Self.buildSettings(settings, configuration: name))
            if let file = configuration.file {
                guard case .file(let ref) = try loaded.resolve(file) else {
                    throw ConversionError("Xcode configuration must reference an xcconfig file: \(file)")
                }
                result.baseConfigurationFileReference = ref.id
            }
            return result
        }
    }

    // xcproj stores per-configuration settings using [config=...] conditions. PIF stores
    // a settings table per configuration and flattens list values to space-separated strings.
    static func buildSettings(
        _ settings: [String: XCSchema.BuildSetting], configuration: String
    ) -> XPIF.BuildSettings {
        var result = XPIF.BuildSettings()
        let expression = /\[config=([^\]]*)\]/
        let ordered = settings.sorted { lhs, rhs in
            func priority(_ key: String) -> Int {
                let matches = key.matches(of: expression)
                guard !matches.isEmpty else { return 0 }
                let wildcard = matches.contains { match in
                    match.output.1.contains("*") || match.output.1.contains("?")
                }
                return wildcard ? 1 : 2
            }
            let left = priority(lhs.key)
            let right = priority(rhs.key)
            return left == right ? lhs.key < rhs.key : left < right
        }
        for (rawKey, value) in ordered {
            let matches = rawKey.matches(of: expression)
            let applies = matches.allSatisfy { match in
                let pattern = match.output.1.reduce(Regex<Substring>(verbatim: "")) { prefix, character in
                    let suffix: Regex<Substring> = switch character {
                    case "*": Regex { ZeroOrMore(.any) }
                    case "?": Regex { CharacterClass.any }
                    default: Regex(verbatim: String(character))
                    }
                    return Regex {
                        prefix
                        suffix
                    }
                }
                return configuration.wholeMatch(of: pattern) != nil
            }
            guard applies else { continue }
            let key = rawKey.replacing(expression, with: "")
            result.values[key] = switch value {
            case .string(let string): .string(string)
            case .array(let array): .string(array.joined(separator: " "))
            }
        }
        return result
    }

    mutating func convertTarget(
        _ source: XCSchema.Target, projects: OrderedDictionary<URL, XcodeLoadedProject>
    ) throws -> XPIF.BaseTarget {
        let properties = source.commonProperties
        let id = loaded.guid(properties.objectID)
        try addPackageMemberships(properties)
        var configurations = project.configurations
        for specialized in properties.specializedConfigurations {
            guard let index = configurations.firstIndex(where: { $0.name == specialized.name }) else {
                throw ConversionError("Unknown configuration in target \(properties.name): \(specialized.name.rawValue)")
            }
            configurations[index] = specialized
        }
        // Project configuration IDs and xcconfigs belong to the project, not the target.
        for index in configurations.indices {
            if !properties.specializedConfigurations.contains(where: { $0.name == configurations[index].name }) {
                configurations[index].objectID = nil
                configurations[index].file = nil
            }
        }
        let configs = try buildConfigurations(configurations, settings: properties.buildSettings, ownerID: id)
        let phases = try properties.buildPhases.enumerated().map { try convertPhase($0.element, target: properties, index: $0.offset) }
        let rules = try buildRules(properties, ownerID: id)
        let dependencies = try targetDependencies(properties.dependencies, projects: projects) + packageDependencies(properties)
        var result: XPIF.BaseTarget
        switch source {
        case .native:
            guard let productType = properties.productTypeID else {
                throw ConversionError("Missing product type for Xcode target \(properties.name).")
            }
            let product: XPIF.FileReference
            if let reference = properties.product, case .file(let file) = try loaded.resolve(reference) {
                product = file
            } else {
                throw ConversionError("Missing product reference for Xcode target \(properties.name).")
            }
            var target = XPIF.Target(id: id, productType: .init(rawValue: productType.rawValue),
                                     name: properties.name, productName: product.path)
            target.productReference = .init(id: product.id, name: product.path)
            target.classPrefix = project.classPrefix
            target.predominantSourceCodeLanguage = predominantLanguage(in: phases)
            target.provisioningSourceData = configs.map { config in
                .init(configurationName: config.name,
                      provisioningStyle: config.settings[single: "CODE_SIGN_STYLE"] == "Manual" ? .manual : .automatic,
                      bundleIdentifierFromInfoPlist: bundleIdentifierFromInfoPlist(config))
            }
            result = .target(target)
        case .aggregate:
            var target = XPIF.AggregateTarget(id: id, name: properties.name)
            if let prefix = project.classPrefix { target.common.additionalFields["classPrefix"] = .string(prefix) }
            target.common.additionalFields["provisioningSourceData"] = .array(configs.map { config in
                .object(["configurationName": .string(config.name), "provisioningStyle": .number(0),
                         "bundleIdentifierFromInfoPlist": .string("")])
            })
            result = .aggregate(target)
        case .externalBuildSystem(let external):
            guard phases.isEmpty, rules.isEmpty else {
                throw ConversionError("External Xcode targets with build phases or build rules are unsupported.")
            }
            result = .external(.init(
                id: id, name: properties.name, toolPath: .string(external.buildToolPath),
                arguments: .string(external.buildToolArguments),
                workingDirectory: .string(external.buildToolWorkingDirectory ?? "$(PROJECT_DIR)"),
                passBuildSettingsInEnvironment: external.passBuildSettingsInEnvironment
            ))
        }
        result.common.buildConfigs = configs
        result.common.buildPhases = phases
        result.common.buildRules = rules
        result.common.dependencies = dependencies
        return result
    }

    private mutating func addPackageMemberships(_ properties: XCSchema.CommonTargetProperties) throws {
        let id = loaded.guid(properties.objectID)
        for (index, member) in properties.packageProductTargetMembers.enumerated() {
            let reference: XCSchema.ProjectBuildPhaseReference = switch member.buildFile.buildPhase {
            case .objectID(let id): .objectID(id)
            case .named(let kind, let name): .named(target: .init(targetName: properties.name), kind: kind, name: name)
            }
            try addMembership(.init(objectID: member.packageProduct.objectID ?? member.buildFile.objectID, buildPhase: reference,
                                    properties: member.buildFile.properties),
                              ref: .targetProduct(id: packageProduct(member.packageProduct).id),
                              fallback: "\(id.value)::PACKAGE:\(index)")
        }
    }

    private func packageDependencies(_ properties: XCSchema.CommonTargetProperties) throws -> [XPIF.TargetDependency] {
        let explicit = try Set(properties.dependencies.compactMap { dependency -> XPIF.GUID? in
            guard case .package(let reference, _) = dependency else { return nil }
            return try packageProduct(reference).id
        })
        var seen = explicit
        return try properties.packageProductTargetMembers.compactMap { member in
            let product = try packageProduct(member.packageProduct)
            guard seen.insert(product.id).inserted else { return nil }
            var dependency = XPIF.TargetDependency(targetId: product.id)
            dependency.additionalFields["name"] = .string(member.packageProduct.productName)
            return dependency
        }
    }

    private func bundleIdentifierFromInfoPlist(_ configuration: XPIF.BuildConfig) -> String {
        let projectSettings = Self.buildSettings(project.buildSettings, configuration: configuration.name)
        let settings = projectSettings.values.merging(configuration.settings.values) { _, target in target }
        if case .string(let path) = settings["INFOPLIST_FILE"],
           let filePath = try? XCSchema.FilePath(base: .project, path: path),
           let url = loaded.xcodeProject.resolve(filePath, relativeTo: loaded.sourceRoot),
           let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let identifier = plist["CFBundleIdentifier"] as? String {
            return identifier
        }
        return settings["GENERATE_INFOPLIST_FILE"] == .string("YES") ? "$(PRODUCT_BUNDLE_IDENTIFIER)" : ""
    }

    private func predominantLanguage(in phases: [XPIF.BuildPhase]) -> String? {
        // Xcode counts build-file memberships by file type, including headers/copy phases.
        var counts: [String: Int] = [:]
        for file in phases.flatMap({ $0.common.files }) {
            guard case .reference(let id) = file.ref, let type = loaded.fileTypes[id] else { continue }
            counts[type, default: 0] += 1
        }
        let languages = counts.compactMap { type, count -> (name: String, count: Int)? in
            let language: String
            switch type {
            case "sourcecode.swift": language = "Swift"
            case "sourcecode.c.c": language = "C"
            case "sourcecode.c.objc": language = "Objective-C"
            case "sourcecode.cpp.cpp": language = "C-Plus-Plus"
            case "sourcecode.c.h", "sourcecode.cpp.h", "sourcecode.cpp.objcpp": language = "Objective-C-Plus-Plus"
            case "net.daringfireball.markdown": language = "Markdown"
            default: return nil
            }
            return (language, count)
        }
        let language = languages.min {
            $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count
        }
        return language.map { "Xcode.SourceCodeLanguage.\($0.name)" }
    }

    func targetDependencies(
        _ dependencies: [XCSchema.TargetDependency], projects: OrderedDictionary<URL, XcodeLoadedProject>
    ) throws -> [XPIF.TargetDependency] {
        try dependencies.map { dependency -> XPIF.TargetDependency in
            switch dependency {
            case .localTarget(let target, let filters):
                var result = XPIF.TargetDependency(
                    targetId: loaded.guid(try loaded.resolveTarget(target.targetName).objectID),
                    platformFilters: Self.platformFilters(filters)
                )
                result.additionalFields["name"] = .string(target.targetName)
                return result
            case .remoteTarget(let target, let filters):
                let remote = try referencedProject(target.project, in: projects)
                guard remote.project.targets.contains(where: { $0.commonProperties.objectID == target.targetID }) else {
                    throw ConversionError("Unknown target \(target.targetID.rawValue) in \(remote.projectURL.path)")
                }
                var result = XPIF.TargetDependency(
                    targetId: remote.guid(target.targetID), platformFilters: Self.platformFilters(filters)
                )
                let name = remote.project.targets.first { $0.commonProperties.objectID == target.targetID }?.name ?? target.target
                let suffix = " (from \(remote.projectURL.lastPathComponent))"
                result.additionalFields["name"] = .string(name + suffix)
                return result
            case .package(let reference, let filters):
                var result = XPIF.TargetDependency(targetId: try packageProduct(reference).id,
                                                   platformFilters: Self.platformFilters(filters))
                result.additionalFields["name"] = .string(reference.productName)
                return result
            }
        }
    }

    mutating func buildRules(_ properties: XCSchema.CommonTargetProperties, ownerID id: XPIF.GUID) throws -> [XPIF.BuildRule] {
        try properties.buildRules.enumerated().map { index, rule in
            let ruleID = try identifier(rule.objectID, fallback: "\(id.value)::RULE:\(index)")
            let input: XPIF.BuildRule.Input = if let pattern = rule.filePatterns {
                .filePattern(pattern)
            } else {
                .fileType(rule.fileType?.rawValue ?? "file")
            }
            let action: XPIF.BuildRule.Action = if let script = rule.script {
                .shellScriptWithFileList(
                    script, inputPaths: rule.inputFiles, inputFileListPaths: rule.inputFileLists,
                    outputPaths: rule.outputFiles, outputFileListPaths: rule.outputFileLists,
                    outputFilesCompilerFlags: rule.outputFilesCompilerFlags.isEmpty ? nil : rule.outputFilesCompilerFlags,
                    dependencyInfo: rule.dependencyFile.map { .makefile($0) }, runOncePerArchitecture: rule.runOncePerArchitecture
                )
            } else {
                .compiler(rule.processor)
            }
            let name = rule.name ?? rule.filePatterns.map { "Files '\($0)' using Script" } ?? ""
            return XPIF.BuildRule(id: ruleID, name: name, input: input, action: action)
        }
    }

    mutating func convertPhase(
        _ phase: XCSchema.BuildPhase, target: XCSchema.CommonTargetProperties, index: Int
    ) throws -> XPIF.BuildPhase {
        let id = try identifier(phase.properties.objectID, fallback: loaded.phaseID(phase, target: target, index: index).value)
        var files = phaseFiles[id] ?? []
        for index in files.indices {
            files[index].generatedCodeVisibility = generatedCodeVisibility(for: files[index], in: phase)
        }
        switch phase {
        case .headers: return .headers(.init(id: id, files: files))
        case .sources: return .sources(.init(id: id, files: files))
        case .frameworks: return .frameworks(.init(id: id, files: files))
        case .resources: return .copyBundleResources(.init(id: id, files: files))
        case .copy(let properties):
            return .copyFiles(.init(
                common: .init(id: id, files: files), destinationSubfolder: Self.copyDestination(properties.bundleBasePath),
                destinationSubpath: properties.relativePath, runOnlyForDeploymentPostprocessing: properties.scope == .install
            ))
        case .script(let properties):
            guard files.isEmpty else { throw ConversionError("Shell script build phases cannot contain build files.") }
            var script = XPIF.ShellScriptBuildPhase(
                id: id, name: properties.baseProperties.name ?? "Run Script", scriptContents: properties.script,
                shellPath: properties.shellPath, inputPaths: properties.inputPaths, outputPaths: properties.outputPaths,
                emitEnvironment: properties.logEnvironmentVariables, alwaysOutOfDate: properties.runOnEveryBuild,
                runOnlyForDeploymentPostprocessing: properties.scope == .install,
                originalObjectID: properties.baseProperties.objectID?.rawValue ?? id.value
            )
            script.inputFileListPaths = properties.inputFileListPaths
            script.outputFileListPaths = properties.outputFileListPaths
            script.dependencyInfo = properties.dependencyFile.map { .makefile($0) }
            return .shellScript(script)
        case .appleScript, .javaArchive, .rez:
            throw ConversionError("Unsupported Xcode build phase: \(phase.kind.rawValue)")
        }
    }

    // Each case maps one Xcode bundle location to its PIF build setting.
    // swiftlint:disable:next cyclomatic_complexity
    static func copyDestination(_ base: XCSchema.BundleBasePath?) -> XPIF.CopyFilesBuildPhase.DestinationSubfolder {
        switch base {
        case nil: .absolute
        case .productDir: .builtProductsDir
        case .root: .wrapper
        case .resourcesDir: .resources
        case .frameworksDir: .frameworks
        case .sharedFrameworksDir: .sharedFrameworks
        case .sharedSupportDir: .sharedSupport
        case .javaDir: .javaResources
        case .plugInsDir: .plugins
        case .pkgInfo: .buildSetting("$(PKGINFO_FILE_PATH)")
        case .appleScriptsDir: .buildSetting("$(SCRIPTS_FOLDER_PATH)")
        case .privateHeadersDir: .buildSetting("$(PRIVATE_HEADERS_FOLDER_PATH)")
        case .headersDir: .buildSetting("$(PUBLIC_HEADERS_FOLDER_PATH)")
        case .contentsDir: .buildSetting("$(CONTENTS_FOLDER_PATH)")
        case .executablesDir: .buildSetting("$(EXECUTABLE_FOLDER_PATH)")
        case .infoPlist: .buildSetting("$(INFOPLIST_PATH)")
        case .mainExecutable: .buildSetting("$(EXECUTABLE_PATH)")
        case .mainExecutableShallow: .buildSetting("$(EXECUTABLE_NAME)")
        }
    }
}
