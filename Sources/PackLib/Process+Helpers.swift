import Foundation

extension Process {
    /// Launches the process and suspends until the receiver is finished.
    ///
    /// - Parameter onCancel: The action to take if the current
    /// task is cancelled.
    public func runUntilExit(onCancel: TaskCancelAction = .interrupt) async throws {
        try Task.checkCancellation()

        let (terminationStream, terminationContinuation) = AsyncStream<Never>.makeStream()
        terminationHandler = { _ in
            terminationContinuation.finish()
        }

        do {
            try run()
        } catch {
            terminationContinuation.finish()
            throw error
        }

        await withTaskCancellationHandler {
            for await _ in terminationStream {}
        } onCancel: {
            switch onCancel {
            case .interrupt:
                interrupt()
            case .terminate:
                terminate()
            case .ignore:
                break
            }
        }

        try Task.checkCancellation()

        switch terminationReason {
        case .exit where terminationStatus == 0:
            break
        case .exit:
            throw Failure.exit(terminationStatus)
        case .uncaughtSignal:
            throw Failure.uncaughtSignal(terminationStatus)
        @unknown default:
            break
        }
    }

    public enum Failure: Error {
        case exit(CInt)
        case uncaughtSignal(CInt)
    }

    public enum TaskCancelAction: Sendable {
        /// Sends `SIGINT` to the process.
        case interrupt
        /// Sends `SIGTERM` to the process.
        case terminate
        /// Don't participate in cooperative cancellation.
        case ignore
    }
}
