import Foundation
import Subprocess

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
    /// - Throws: `Errors.toolNotFound` if the tool could not be located.
    package static func locate(_ tool: String) async throws -> URL {
        try await cache.locate(tool: tool)
    }

    private actor Cache {
        private var cache: [String: Task<URL, Error>] = [:]

        private func _locate(tool: String) async throws -> URL {
            guard let path = try? Executable.name(tool).resolveExecutablePath(in: .inherit),
                  let url = URL(filePath: path)
                  else { throw Errors.toolNotFound(tool) }
            return url
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
