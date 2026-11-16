// Adapted from SwiftBuild/BuildRule.swift: mutable Xcode PIF support and lossless JSON fields.

import Foundation

extension XPIF {
    public struct BuildRule: Sendable, Hashable, Identifiable {
        public enum Input: Sendable, Hashable {
            case fileType(_ identifier: String)
            case filePattern(_ pattern: String)
        }

        public enum Action: Sendable, Hashable {
            case compiler(_ identifier: String)
            case shellScriptWithFileList(_ contents: String, inputPaths: [String], inputFileListPaths: [String], outputPaths: [String], outputFileListPaths: [String], outputFilesCompilerFlags: [String]?, dependencyInfo: DependencyInfoFormat?, runOncePerArchitecture: Bool)

            public enum DependencyInfoFormat: Sendable, Hashable {
                case dependencyInfo(String)
                case makefile(String)
                case makefiles([String])
            }
        }

        public let id: GUID
        public var name: String
        public var input: Input
        public var action: Action
        public var additionalFields: [String: JSONValue] = [:]

        public init(id: GUID, name: String, input: Input, action: Action) {
            self.id = id
            self.name = name
            self.input = input
            self.action = action
        }
    }
}


extension XPIF.BuildRule: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        var dict: [String: Value] = [:]
        for key in keyed.allKeys {
            dict[key.stringValue] = try keyed.decode(Value.self, forKey: key)
        }
        self.additionalFields = try decodeAdditionalFields(from: decoder, excluding: CodingKeys.self)
        guard let id = dict["guid"]?.string,
              let name = dict["name"]?.string,
              let typeId = dict["fileTypeIdentifier"]?.string
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unable to find expected values")
        }
        self.id = XPIF.GUID(id)
        self.name = name

        if typeId == "pattern.proxy",
           let pattern = dict["filePatterns"]?.string {
            self.input = .filePattern(pattern)
        } else {
            self.input = .fileType(typeId)
        }

        switch dict["compilerSpecificationIdentifier"]?.string {
        case "com.apple.compilers.proxy.script":
            guard let contents = dict["scriptContents"]?.string,
                  let inputPaths = dict["inputFilePaths"]?.array,
                  let outputPaths = dict["outputFilePaths"]?.array
            else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Failed to decode proxy script information.")
            }

            let inputFileListPaths = dict["inputFileListPaths"]?.array ?? []
            let outputFileListPaths = dict["outputFileListPaths"]?.array ?? []

            let outputFilesCompilerFlags = dict["outputFilesCompilerFlags"]?.array
            let runOncePerArchitecture = dict["runOncePerArchitecture"]?.string == "true"

            let dependencyInfo: Action.DependencyInfoFormat?
            if let format = dict["dependencyFileFormat"]?.string,
               let paths = dict["dependencyFilePaths"]?.array {

                dependencyInfo = try .init(format: format, paths: paths, codingPath: decoder.codingPath)
            } else {
                dependencyInfo = nil
            }

            self.action = .shellScriptWithFileList(contents, inputPaths: inputPaths, inputFileListPaths: inputFileListPaths, outputPaths: outputPaths, outputFileListPaths: outputFileListPaths, outputFilesCompilerFlags: outputFilesCompilerFlags, dependencyInfo: dependencyInfo, runOncePerArchitecture: runOncePerArchitecture)
        case let .some(specId):
            self.action = .compiler(specId)
        case .none:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Failed to decode action information.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeAdditionalFields(additionalFields, to: encoder, excluding: CodingKeys.self)
        var container = encoder.container(keyedBy: StringKey.self)
        for (key, value) in serialize() {
            try container.encode(value, forKey: StringKey(key))
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case guid, name, fileTypeIdentifier, filePatterns, compilerSpecificationIdentifier, scriptContents
        case inputFilePaths, inputFileListPaths, outputFilePaths, outputFileListPaths, outputFilesCompilerFlags
        case dependencyFileFormat, dependencyFilePaths, runOncePerArchitecture
    }

    private enum Value: Codable {
        case str(String)
        case arr([String])

        fileprivate var string: String? {
            switch self {
            case .str(let str): return str
            case .arr: return nil
            }
        }

        fileprivate var array: [String]? {
            switch self {
            case .str(_): return nil
            case .arr(let arr): return arr
            }
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case .str(let str): try str.encode(to: encoder)
            case .arr(let arr): try arr.encode(to: encoder)
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self) {
                self = .str(str)
            } else if let arr = try? container.decode([String].self) {
                self = .arr(arr)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected string or array in container.")
            }
        }
    }

    // TODO: fold this into 'encode'
    private func serialize() -> [String: Value] {
        var dict: [String: Value] = [:]
        dict["guid"] = .str(id.value)
        dict["name"] = .str(name)
        switch self.input {
        case .fileType(let typeId):
            dict["fileTypeIdentifier"] = .str(typeId)
        case .filePattern(let pattern):
            dict["fileTypeIdentifier"] = .str("pattern.proxy")
            dict["filePatterns"] = .str(pattern)
        }

        func populateDictFromShellScript(_ contents: String, inputPaths: [String], inputFileListPaths: [String]?, outputPaths: [String], outputFileListPaths: [String]?, outputFilesCompilerFlags: [String]?, dependencyInfo: Action.DependencyInfoFormat?, runOncePerArchitecture: Bool) {
            dict["compilerSpecificationIdentifier"] = .str("com.apple.compilers.proxy.script")
            dict["scriptContents"] = .str(contents)
            dict["inputFilePaths"] = .arr(inputPaths)
            if let inputFileListPaths {
                dict["inputFileListPaths"] = .arr(inputFileListPaths)
            }
            dict["outputFilePaths"] = .arr(outputPaths)
            if let outputFileListPaths {
                dict["outputFileListPaths"] = .arr(outputFileListPaths)
            }
            if let outputFilesCompilerFlags = outputFilesCompilerFlags {
                dict["outputFilesCompilerFlags"] = .arr(outputFilesCompilerFlags)
            }
            if let dependencyInfo = dependencyInfo {
                let pifInfo: (format: String, paths: [String])
                switch dependencyInfo {
                case .dependencyInfo(let path):
                    pifInfo = (format: "dependencyInfo", paths: [path])
                case .makefile(let path):
                    pifInfo = (format: "makefile", paths: [path])
                case .makefiles(let paths):
                    pifInfo = (format: "makefiles", paths: paths)
                }
                dict["dependencyFileFormat"] = .str(pifInfo.format)
                dict["dependencyFilePaths"] = .arr(pifInfo.paths)
            }
            dict["runOncePerArchitecture"] = runOncePerArchitecture ? .str("true") : .str("false")
        }

        switch self.action {
        case .compiler(let specId):
            dict["compilerSpecificationIdentifier"] = .str(specId)
        case .shellScriptWithFileList(let contents, let inputPaths, let inputFileListPaths, let outputPaths, let outputFileListPaths, let outputFilesCompilerFlags, let dependencyInfo, let runOncePerArchitecture):
            populateDictFromShellScript(contents, inputPaths: inputPaths, inputFileListPaths: inputFileListPaths, outputPaths: outputPaths, outputFileListPaths: outputFileListPaths, outputFilesCompilerFlags: outputFilesCompilerFlags, dependencyInfo: dependencyInfo, runOncePerArchitecture: runOncePerArchitecture)
        }
        return dict
    }
}


extension XPIF.BuildRule.Action.DependencyInfoFormat {
    init(format: String, paths: [String], codingPath: [any CodingKey]) throws {
        switch format {
        case "dependencyInfo" where paths.count == 1: self = .dependencyInfo(paths[0])
        case "makefile" where paths.count == 1: self = .makefile(paths[0])
        case "makefiles": self = .makefiles(paths)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Invalid dependency file format or paths"))
        }
    }

    var formatAndPaths: (format: String, paths: [String]) {
        switch self {
        case .dependencyInfo(let path): ("dependencyInfo", [path])
        case .makefile(let path): ("makefile", [path])
        case .makefiles(let paths): ("makefiles", paths)
        }
    }
}
