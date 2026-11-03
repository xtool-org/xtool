import Dependencies
import Foundation
import Subprocess
import XUtils

/// swift-frontend proxy that applies some fixes to hot-reloadable builds.
/// 
/// Only active when `@Dependency(\.isHotReloadableBuild)` is `true`.
struct SwiftCompilerTool: EmulatedTool {
    var name: String { "swift-frontend" }

    func execute(
        commandLine: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> EmulatedToolResult {
        guard d.isHotReloadableBuild else { return .deferred }

        // The frontend unconditionally emits some symbols with hidden visibility, notably
        // default arguments of public functions. When another file in the same module uses
        // these, hot reloading that file fails (the dylib doesn't have access to the symbol).
        // Fix this by exposing these symbols.

        let arguments = try Self.expandResponseFiles(Array(commandLine.dropFirst()))
        guard arguments.first == "-frontend", arguments.contains("-c") else { return .deferred }

        let result = try await Subprocess.run(
            .path(FilePath(commandLine[0])),
            arguments: Arguments(Array(commandLine.dropFirst())),
            environment: Environment(environment),
            workingDirectory: workingDirectory.map { FilePath($0) },
            output: .data(limit: .max),
            error: .data(limit: .max),
        )
        guard result.terminationStatus.isSuccess else { return result.emulatedToolResult }

        let base = workingDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) }
        // one -o per primary file
        for (index, argument) in arguments.enumerated() where argument == "-o" {
            guard arguments.indices.contains(index + 1) else { continue }
            try MachOSymbolExporter.exportHiddenSwiftSymbols(
                in: URL(filePath: arguments[index + 1], relativeTo: base)
            )
        }
        return result.emulatedToolResult
    }

    // The driver moves arguments into a response file when they exceed `ARG_MAX`.
    private static func expandResponseFiles(_ arguments: [String]) throws -> [String] {
        try arguments.flatMap { argument -> [String] in
            guard argument.hasPrefix("@") else { return [argument] }
            let contents = try String(contentsOfFile: String(argument.dropFirst()), encoding: .utf8)
            // one shell-escaped argument per line
            return contents.split(separator: "\n").map { line in
                guard line.count >= 2, line.hasPrefix("'"), line.hasSuffix("'") else { return String(line) }
                return String(line.dropFirst().dropLast()).replacing(#"'\''"#, with: "'")
            }
        }
    }
}

enum MachOSymbolExporter {
    private static let magic64: UInt32 = 0xfeed_facf
    private static let symtabCommand: UInt32 = 0x2
    private static let headerSize = 32
    private static let nlistSize = 16

    // n_type bits
    private static let stab: UInt8 = 0xe0
    private static let privateExternal: UInt8 = 0x10
    private static let typeMask: UInt8 = 0x0e
    private static let definedInSection: UInt8 = 0x0e
    private static let external: UInt8 = 0x01

    /// Clears `N_PEXT` on defined Swift symbols in the 64-bit Mach-O object at `url`.
    /// Leaves other files untouched.
    static func exportHiddenSwiftSymbols(in url: URL) throws {
        var bytes = [UInt8](try Data(contentsOf: url))
        guard exportHiddenSwiftSymbols(in: &bytes) else { return }
        try Data(bytes).write(to: url)
    }

    /// Returns whether any symbols were changed.
    static func exportHiddenSwiftSymbols(in bytes: inout [UInt8]) -> Bool {
        func read<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T? {
            guard offset >= 0, offset + MemoryLayout<T>.size <= bytes.count else { return nil }
            return bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
        }

        guard read(UInt32.self, at: 0) == magic64,
              let commandCount = read(UInt32.self, at: 16)
        else { return false }

        var changed = false
        var commandOffset = headerSize
        for _ in 0..<commandCount {
            guard let command = read(UInt32.self, at: commandOffset),
                  let commandSize = read(UInt32.self, at: commandOffset + 4),
                  commandSize > 0
            else { break }
            defer { commandOffset += Int(commandSize) }
            guard command == symtabCommand,
                  let symbolOffset = read(UInt32.self, at: commandOffset + 8).map(Int.init),
                  let symbolCount = read(UInt32.self, at: commandOffset + 12).map(Int.init),
                  let stringOffset = read(UInt32.self, at: commandOffset + 16).map(Int.init)
            else { continue }

            for index in 0..<symbolCount {
                let entry = symbolOffset + index * nlistSize
                guard let nameOffset = read(UInt32.self, at: entry).map({ stringOffset + Int($0) }),
                      let type = read(UInt8.self, at: entry + 4)
                else { break }
                guard type & stab == 0,
                      type & privateExternal != 0,
                      type & external != 0,
                      type & typeMask == definedInSection,
                      bytes.count > nameOffset + 3,
                      bytes[nameOffset..<(nameOffset + 3)].elementsEqual("_$s".utf8)
                else { continue }
                bytes[entry + 4] = type & ~privateExternal
                changed = true
            }
        }
        return changed
    }
}

private enum IsHotReloadableBuildKey: DependencyKey {
    static let liveValue = false
    static let testValue = false
}

extension DependencyValues {
    /// Whether the current build is hot-reloadable
    var isHotReloadableBuild: Bool {
        get { self[IsHotReloadableBuildKey.self] }
        set { self[IsHotReloadableBuildKey.self] = newValue }
    }
}
