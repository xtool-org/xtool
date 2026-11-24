import Foundation

extension XPIF {
    public struct ExternalTarget: Common, Identifiable, Sendable, Hashable, Codable {
        public var common: TargetCommon
        public var id: GUID { common.id }
        public var toolPath: StringList
        public var arguments: StringList
        public var workingDirectory: StringList
        public var passBuildSettingsInEnvironment: Bool

        public init(
            id: GUID,
            name: String,
            toolPath: StringList,
            arguments: StringList = .string(""),
            workingDirectory: StringList = .string(""),
            passBuildSettingsInEnvironment: Bool = true
        ) {
            self.common = .init(id: id, name: name)
            self.toolPath = toolPath
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.passBuildSettingsInEnvironment = passBuildSettingsInEnvironment
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            common = .init(
                id: try container.decode(GUID.self, forKey: .guid),
                name: try container.decode(String.self, forKey: .name),
                buildConfigs: try container.decodeIfPresent([BuildConfig].self, forKey: .buildConfigurations) ?? [],
                dependencies: try container.decodeIfPresent([TargetDependency].self, forKey: .dependencies) ?? [],
                customTasks: try container.decodeIfPresent([CustomTask].self, forKey: .customTasks) ?? []
            )
            toolPath = try container.decode(StringList.self, forKey: .toolPath)
            arguments = try container.decodeIfPresent(StringList.self, forKey: .arguments) ?? .string("")
            workingDirectory = try container.decodeIfPresent(StringList.self, forKey: .workingDirectory) ?? .string("")
            passBuildSettingsInEnvironment = try container.decodePIFBool(forKey: .passBuildSettingsInEnvironment, default: true)
            common.additionalFields = try decodeAdditionalFields(from: decoder, excluding: CodingKeys.self)
        }

        public func encode(to encoder: any Encoder) throws {
            try encodeAdditionalFields(common.additionalFields, to: encoder, excluding: CodingKeys.self)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("external", forKey: .type)
            try container.encode(id, forKey: .guid)
            try container.encode(common.name, forKey: .name)
            try container.encode(common.buildConfigs, forKey: .buildConfigurations)
            try container.encode(common.dependencies, forKey: .dependencies)
            if !common.customTasks.isEmpty { try container.encode(common.customTasks, forKey: .customTasks) }
            try container.encode(toolPath, forKey: .toolPath)
            try container.encode(arguments, forKey: .arguments)
            try container.encode(workingDirectory, forKey: .workingDirectory)
            try container.encode(passBuildSettingsInEnvironment ? "true" : "false", forKey: .passBuildSettingsInEnvironment)
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case type, guid, name, buildConfigurations, dependencies, customTasks
            case toolPath, arguments, workingDirectory, passBuildSettingsInEnvironment
        }
    }
}
