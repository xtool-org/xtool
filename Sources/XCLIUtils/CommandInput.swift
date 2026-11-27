import Dependencies
import Foundation
import XUtils

package struct CommandInput: DependencyKey, Sendable {
    // nil = EOF
    private let readImpl: @Sendable (DataChannel.Limit) async throws -> Data?

    package init(
        read: @escaping @Sendable (DataChannel.Limit) async throws -> Data?,
    ) {
        self.readImpl = read
    }

    package init(channel: DataChannel) {
        self.init(read: { try await channel.read(upTo: $0) })
    }

    package func read(upTo limit: DataChannel.Limit = .unlimited) async throws -> Data? {
        try Task.checkCancellation()
        return try await readImpl(limit)
    }

    /// Cancellation discards bytes already consumed for this line.
    package func readLine() async throws -> String? {
        var line = Data()
        while let chunk = try await read(upTo: .newline) {
            line.append(chunk)
            if line.last == UInt8(ascii: "\n") {
                line.removeLast()
                return String(decoding: line, as: UTF8.self).trimmingTrailingCarriageReturn()
            }
        }
        guard !line.isEmpty else { return nil }
        return String(decoding: line, as: UTF8.self).trimmingTrailingCarriageReturn()
    }

    package static var liveValue: CommandInput {
        @Dependency(\.shutdownRegistry) var shutdownRegistry
        do {
            let input = try DispatchInput(fileDesciptor: .standardInput)
            shutdownRegistry.register { await input.close() }
            return Self(read: { try await input.read(upTo: $0) })
        } catch {
            return Self(read: { _ in throw error })
        }
    }

    package static var testValue: CommandInput {
        Self(read: unimplemented("CommandInput.read", placeholder: nil))
    }
}

private extension String {
    func trimmingTrailingCarriageReturn() -> String {
        hasSuffix("\r") ? String(dropLast()) : self
    }
}

extension DependencyValues {
    package var input: CommandInput {
        get { self[CommandInput.self] }
        set { self[CommandInput.self] = newValue }
    }
}
