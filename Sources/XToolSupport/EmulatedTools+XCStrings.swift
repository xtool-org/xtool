import Foundation

/// Emulates `xcstringstool`, which swift-build uses to compile String Catalogs
/// (`.xcstrings`) but which only ships with Xcode.
///
/// Supports the two invocations swift-build makes (see `XCStringsCompilerSpec`):
///
/// - `xcstringstool compile [--dry-run] [-l <lang>]... [--force-build-all-strings]
///   --output-directory <dir> <file.xcstrings>`
///   During planning, `--dry-run` prints the absolute paths of the files that will be
///   produced, one per line; the real run writes them.
/// - `xcstringstool generate-symbols --language swift --output-directory <dir> <file.xcstrings>`
///   (with `STRING_CATALOG_GENERATE_SYMBOLS = YES`, the default for localized packages).
///   Symbol generation isn't supported yet, so this writes an empty source file, and a
///   warning if the catalog has manually managed strings (the only ones with symbols).
struct XCStringsTool: EmulatedTool {
    var name: String { "xcstringstool" }

    struct UsageError: Error, CustomStringConvertible {
        var description: String
    }

    func execute(
        commandLine: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> EmulatedToolResult {
        let directory = URL(
            fileURLWithPath: workingDirectory ?? FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        var input: String?
        do {
            let arguments = try Arguments(Array(commandLine.dropFirst()))
            input = arguments.input
            let output = try run(arguments, in: directory)
            return .result(status: .exit(0), stdout: Data(output.stdout.utf8), stderr: Data(output.stderr.utf8))
        } catch {
            // swift-build scrapes `[<file>: ]error: <message>` lines from stderr.
            let prefix = input.map { "\($0): " } ?? "xcstringstool: "
            return .result(status: .exit(1), stdout: Data(), stderr: Data("\(prefix)error: \(error)\n".utf8))
        }
    }

    private func run(_ arguments: Arguments, in directory: URL) throws -> (stdout: String, stderr: String) {
        let input = URL(fileURLWithPath: arguments.input, relativeTo: directory).standardizedFileURL
        let outputDirectory = URL(
            fileURLWithPath: arguments.outputDirectory,
            isDirectory: true,
            relativeTo: directory
        ).standardizedFileURL
        let tableName = input.deletingPathExtension().lastPathComponent

        switch arguments.command {
        case .compile:
            var compiler = StringCatalogCompiler(
                languages: arguments.languages.isEmpty ? nil : Set(arguments.languages),
                forceBuildAllStrings: arguments.forceBuildAllStrings
            )
            let outputs = try compiler.compile(catalog: Data(contentsOf: input), tableName: tableName)
            let urls = outputs.map { outputDirectory.appending(path: $0.path) }
            if arguments.dryRun {
                return (urls.map { "\($0.path)\n" }.joined(), "")
            }
            for (output, url) in zip(outputs, urls) {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try output.contents.write(to: url, options: .atomic)
            }
            let warnings = compiler.warnings.map { "\(input.path): warning: \($0)\n" }.joined()
            return ("", warnings)

        case .generateSymbols:
            let url = outputDirectory.appending(path: "GeneratedStringSymbols_\(tableName).swift")
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try Data("// String Catalog symbol generation is not supported by xtool yet.\n".utf8)
                .write(to: url, options: .atomic)
            // swift-build turns symbol generation on for every localized package, but only
            // manually managed strings get symbols, so most catalogs lose nothing.
            guard try StringCatalogCompiler.hasManualStrings(catalog: Data(contentsOf: input)) else {
                return ("", "")
            }
            return ("", """
            \(input.path): warning: symbols for manually managed strings are not generated \
            on this platform\n
            """)
        }
    }

    struct Arguments {
        enum Command {
            case compile
            case generateSymbols
        }

        var command: Command
        var dryRun = false
        var forceBuildAllStrings = false
        var languages: [String] = []
        var outputDirectory: String
        var input: String

        init(_ arguments: [String]) throws {
            guard let first = arguments.first else {
                throw UsageError(description: "missing subcommand")
            }
            switch first {
            case "compile": command = .compile
            case "generate-symbols": command = .generateSymbols
            default: throw UsageError(description: "unsupported subcommand '\(first)'")
            }

            var options = Options()
            var remaining = arguments.dropFirst()[...]
            while let argument = remaining.popFirst() {
                try options.parse(argument, command: command, remaining: &remaining)
            }
            dryRun = options.dryRun
            forceBuildAllStrings = options.forceBuildAllStrings
            languages = options.languages
            guard let outputDirectory = options.outputDirectory else {
                throw UsageError(description: "missing --output-directory")
            }
            guard options.inputs.count == 1, let input = options.inputs.first else {
                throw UsageError(description: "expected exactly one .xcstrings file, got \(options.inputs.count)")
            }
            self.outputDirectory = outputDirectory
            self.input = input
        }
    }

    private struct Options {
        var dryRun = false
        var forceBuildAllStrings = false
        var languages: [String] = []
        var outputDirectory: String?
        var inputs: [String] = []

        mutating func parse(
            _ argument: String,
            command: Arguments.Command,
            remaining: inout ArraySlice<String>
        ) throws {
            func value() throws -> String {
                guard let value = remaining.popFirst() else {
                    throw UsageError(description: "missing value for \(argument)")
                }
                return value
            }
            switch argument {
            case "--dry-run":
                dryRun = true
            case "-l":
                languages.append(try value())
            case "--language" where command == .generateSymbols:
                let language = try value()
                guard language == "swift" else {
                    throw UsageError(description: "unsupported symbol language '\(language)'")
                }
            case "--output-directory":
                outputDirectory = try value()
            case "--force-build-all-strings":
                forceBuildAllStrings = true
            case _ where argument.hasPrefix("-"):
                throw UsageError(description: "unsupported option '\(argument)'")
            default:
                inputs.append(argument)
            }
        }
    }
}
