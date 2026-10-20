import Foundation
import Dependencies

struct EmulatedTools: Sendable, TestDependencyKey {
    var tools: [String: any EmulatedTool]

    init(_ tools: [any EmulatedTool]) {
        self.tools = Dictionary(
            tools.map { ($0.name, $0) },
            uniquingKeysWith: { $1 },
        )
    }

    func execute(
        commandLine: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> EmulatedToolResult {
        guard let toolPath = commandLine.first else { return .deferred }
        let toolURL = URL(fileURLWithPath: toolPath)
        let toolName = toolURL.lastPathComponent
        guard let tool = tools[toolName] else { return .deferred }
        return try await tool.execute(
            commandLine: commandLine,
            workingDirectory: workingDirectory,
            environment: environment,
        )
    }

    static let testValue = Self([])
}

extension DependencyValues {
    var emulatedTools: EmulatedTools {
        get { self[EmulatedTools.self] }
        set { self[EmulatedTools.self] = newValue }
    }
}

protocol EmulatedTool: Sendable {
    var name: String { get }

    func execute(
        commandLine: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> EmulatedToolResult
}

enum EmulatedToolResult: Sendable {
    case deferred
    case result(status: EmulatedToolExitStatus, stdout: Data, stderr: Data)
}

enum EmulatedToolExitStatus: Sendable {
    case exit(_ code: Int32)
    case uncaughtSignal(_ signal: Int32)
}
