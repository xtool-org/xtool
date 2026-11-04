import Foundation
import ConcurrencyExtras

/// A bi-directional channel for streaming data from producer -> consumer.
/// 
/// Supports backpressure via `onRequest`.
public struct DataChannel: Sendable {
    enum Phase {
        case active
        case closed(Error?)
    }

    public enum Errors: Error {
        case concurrentRead
    }

    public struct Limit: Sendable {
        public var limit: @Sendable (Data) throws -> Int

        public init(limit: @escaping @Sendable (Data) throws -> Int) {
            self.limit = limit
        }

        public static var unlimited: Limit {
            Limit { _ in .max }
        }

        public static func bytes(_ count: Int) -> Limit {
            Limit { _ in count }
        }

        public static var newline: Limit {
            Limit { buffer in
                if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    return buffer.distance(from: buffer.startIndex, to: newlineIndex) + 1
                } else {
                    return .max
                }
            }
        }
    }

    private struct State {
        var waiter: (@Sendable () -> Void)?
        var phase: Phase = .active
        var buffer = Data()
        var request: (@Sendable () -> Void)?
    }
    private let state = LockIsolated(State())

    public init() {}

    public func onRequest(_ request: @escaping @Sendable () -> Void) {
        self.state.withValue { $0.request = request }
    }

    public func write(_ data: Data) {
        let waiter: (@Sendable () -> Void)? = self.state.withValue { state in
            guard case .active = state.phase else { return nil }
            state.buffer.append(contentsOf: data)
            return state.waiter.take()
        }
        waiter?()
    }

    public func finish(error: Error?) {
        let waiter: (@Sendable () -> Void)? = self.state.withValue { state in
            guard case .active = state.phase else { return nil }
            state.phase = .closed(error)
            return state.waiter.take()
        }
        waiter?()
    }

    private enum Outcome<T: Sendable>: Sendable {
        case result(Result<T?, Error>)
        case callRequest((@Sendable () -> Void)?)
    }

    nonisolated(nonsending) public func read<T: Sendable>(drain: @Sendable (inout Data) throws -> T) async throws -> T? {
        while true {
            try Task.checkCancellation()

            let result: Result<T?, Error>? = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let outcome: Outcome<T> = state.withValue { state in
                        guard !Task.isCancelled else {
                            return .result(.failure(CancellationError()))
                        }
                        if !state.buffer.isEmpty {
                            return .result(Result { try drain(&state.buffer) })
                        }
                        switch state.phase {
                        case .active:
                            guard state.waiter == nil else {
                                return .result(.failure(Errors.concurrentRead))
                            }
                            state.waiter = { continuation.resume(returning: nil) }
                            return .callRequest(state.request)
                        case .closed(nil):
                            return .result(.success(nil))
                        case .closed(let error?):
                            return .result(.failure(error))
                        }
                    }
                    switch outcome {
                    case .result(let result):
                        continuation.resume(returning: result)
                    case .callRequest(let request):
                        request?()
                    }
                }
            } onCancel: {
                self.state.withValue { $0.waiter.take()?() }
            }

            if let result {
                return try result.get()
            }
        }
    }

    nonisolated(nonsending) public func read(upTo limit: Limit = .unlimited) async throws -> Data? {
        try await self.read { buffer in
            let count = min(try limit.limit(buffer), buffer.count)
            guard count > 0 else { return Data() }
            let result = buffer.prefix(count)
            buffer.removeFirst(count)
            return result
        }
    }
}
