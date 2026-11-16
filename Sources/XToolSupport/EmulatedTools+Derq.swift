import ArgumentParser
import Foundation
import SWBUtil
import SwiftASN1
import XCLIUtils

struct DerqTool: EmulatedTool {
    var name: String { "derq" }

    func execute(
        commandLine: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> EmulatedToolResult {
        do {
            try await execute(commandLine: commandLine, workingDirectory: workingDirectory)
            return .result(status: .exit(0), stdout: Data(), stderr: Data())
        } catch {
            return .result(status: .exit(1), stdout: Data(), stderr: Data("derq: \(error)\n".utf8))
        }
    }

    private func execute(
        commandLine: [String],
        workingDirectory: String?,
    ) async throws {
        guard commandLine.count >= 2, commandLine[1] == "query" else {
            throw Console.Error("Only `derq query` is supported")
        }
        let options = try Query.parse(Array(commandLine.dropFirst(2)))
        guard options.format == "xml", options.raw else {
            throw Console.Error("Only `derq query -f xml -i <plist> -o <der> --raw` is supported")
        }
        let directory = URL(
            fileURLWithPath: workingDirectory ?? FileManager.default.currentDirectoryPath,
            isDirectory: true,
        )
        let input = URL(fileURLWithPath: options.input, relativeTo: directory)
        let output = URL(fileURLWithPath: options.output, relativeTo: directory)
        let encoded = try DerqEncoder().encodeEntitlements(Data(contentsOf: input))
        try encoded.write(to: output)
    }

    private struct Query: ParsableArguments {
        @Option(name: .customShort("f")) var format: String
        @Option(name: .customShort("i")) var input: String
        @Option(name: .customShort("o")) var output: String
        @Flag var raw = false
    }
}

struct DerqEncoder {
    private static let plistDecoder = PropertyListDecoder()

    func encodeEntitlements(_ data: Data) throws -> Data {
        let dictionary = try Self.plistDecoder.decode([String: PropertyListItem].self, from: data)
        var serializer = DER.Serializer()
        try serializer.appendConstructedNode(identifier: .init(tagWithNumber: 16, tagClass: .application)) {
            try $0.serialize(Int64(1))
            try serialize(.plDict(dictionary), into: &$0)
        }
        return Data(serializer.serializedBytes)
    }

    private func serialize(_ value: PropertyListItem, into serializer: inout DER.Serializer) throws {
        switch value {
        case .plBool(let boolean):
            try serializer.serialize(boolean)
        case .plInt(let integer):
            try serializer.serialize(integer)
        case .plString(let string):
            try serializer.serialize(ASN1UTF8String(string))
        case .plArray(let array):
            try serializer.appendConstructedNode(identifier: .sequence) { serializer in
                for element in array {
                    try serialize(element, into: &serializer)
                }
            }
        case .plDict(let dictionary):
            let identifier = ASN1Identifier(tagWithNumber: 16, tagClass: .contextSpecific)
            try serializer.appendConstructedNode(identifier: identifier) { serializer in
                for (key, value) in dictionary.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }) {
                    try serializer.appendConstructedNode(identifier: .sequence) { serializer in
                        try serializer.serialize(ASN1UTF8String(key))
                        try serialize(value, into: &serializer)
                    }
                }
            }
        case .plData, .plDate, .plDouble, .plOpaque:
            throw Console.Error("Unsupported DER entitlement value: \(value.typeDisplayString)")
        }
    }
}
