import PackagePlugin

@main struct GreetingPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target.sourceModule else { return [] }
        let inputs = target.sourceFiles.map(\.url).filter { $0.lastPathComponent == "Greeting.txt" }
        guard let input = inputs.first else {
            throw PluginError("\(target.name) has no Greeting.txt")
        }
        let output = context.pluginWorkDirectoryURL.appending(path: "Greeting.swift")
        return [
            .buildCommand(
                displayName: "Generating Greeting.swift",
                executable: try context.tool(named: "GreetingGenerator").url,
                arguments: [input.path(), output.path()],
                inputFiles: [input],
                outputFiles: [output]
            ),
        ]
    }
}

struct PluginError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
