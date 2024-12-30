import Foundation

enum ToolRegistry {
    enum Errors: Error, CustomStringConvertible {
        case toolNotFound(String)

        var description: String {
            switch self {
            case .toolNotFound(let tool):
                "Could not find executable '\(tool)' in PATH"
            }
        }
    }

    private static let cache = Cache()

    static func locate(_ tool: StaticString) async throws -> URL {
        try await cache.locate(tool: tool)
    }

    private actor Cache {
        private var cache: [String: Task<URL, Error>] = [:]

        private func _locate(tool: String) async throws -> URL {
            let pipe = Pipe()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", "command -v '\(tool)'"]
            proc.standardOutput = pipe
            async let bytes = pipe.fileHandleForReading.readToEnd()
            try proc.run()
            await proc.waitForExit()
            guard proc.terminationStatus == 0 else {
                throw Errors.toolNotFound(tool)
            }
            let path = String(decoding: try await bytes ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(fileURLWithPath: path)
        }

        func locate(tool: StaticString) async throws -> URL {
            let tool = "\(tool)"

            let task: Task<URL, Error>
            if let cached = cache[tool] {
                task = cached
            } else {
                task = Task { try await _locate(tool: tool) }
                cache[tool] = task
            }

            return try await task.value
        }
    }
}
