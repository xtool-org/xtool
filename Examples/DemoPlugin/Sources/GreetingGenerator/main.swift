import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: \(arguments[0]) <input> <output>\n".utf8))
    exit(1)
}
let greeting = try String(contentsOfFile: arguments[1], encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
let source = "let generatedGreeting = \(String(reflecting: greeting))\n"
try source.write(toFile: arguments[2], atomically: true, encoding: .utf8)
