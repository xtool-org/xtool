import Foundation

package enum ToolRegistry {
    package enum Errors: Error, CustomStringConvertible {
        case toolNotFound(String)

        package var description: String {
            switch self {
            case .toolNotFound(let tool):
                "Could not find executable '\(tool)' in PATH"
            }
        }
    }

    private static let cache = Cache()

    /// Obtain the full path to a tool in the user's `PATH`.
    ///
    /// This effectively invokes `/bin/sh -c "command -v '$tool'"`.
    ///
    /// - Warning: Make sure you trust/sanitize the `tool` parameter. If it
    /// contains a single quote, it can be used in a shell escape.
    ///
    /// - Throws: `Errors.toolNotFound` if the tool could not be located.
    package static func locate(_ tool: String) async throws -> URL {
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
            do {
                try await proc.runUntilExit()
            } catch is Process.Failure {
                throw Errors.toolNotFound(tool)
            }
            let path = String(decoding: try await bytes ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(fileURLWithPath: path)
        }

        func locate(tool: String) async throws -> URL {
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
