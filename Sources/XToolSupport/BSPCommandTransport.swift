import ConcurrencyExtras
import Foundation
import BuildServerProtocol
import LanguageServerProtocol
import LanguageServerProtocolTransport
import XCLIUtils
import XUtils

/// Bridges the descriptor-based JSON-RPC connection to task-scoped command streams.
final class BSPCommandTransport: Sendable {
    let connection: JSONRPCConnection
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()

    // Capture the streams before server diagnostics are redirected to stderr.
    private let input = d.input
    private let output = d.out

    init() {
        connection = JSONRPCConnection(
            name: "client",
            protocol: MessageRegistry.bspProtocol,
            receiveFD: inputPipe.fileHandleForReading,
            sendFD: outputPipe.fileHandleForWriting
        )
    }

    func run(receiveHandler: any MessageHandler) async throws {
        let input = self.input
        let output = self.output
        let inputHandle = inputPipe.fileHandleForWriting
        let outputHandle = outputPipe.fileHandleForReading
        let inputQueue = DispatchQueue(label: "bsp-command-input")
        let outputQueue = DispatchQueue(label: "bsp-command-output")
        let outputTask = Task<Void, Never> {
            await withCheckedContinuation { continuation in
                outputQueue.async {
                    defer { continuation.resume() }
                    while true {
                        // Forward promptly instead of waiting to fill a fixed-size read.
                        let data = outputHandle.availableData
                        guard !data.isEmpty else { break }
                        output.write(data, .stdout, false)
                    }
                }
            }
        }
        let (closed, continuation) = AsyncStream.makeStream(of: Never.self)
        connection.start(receiveHandler: receiveHandler, closeHandler: { continuation.finish() })
        let inputError = LockIsolated<(any Error)?>(nil)
        let inputTask = Task {
            defer { try? inputHandle.close() }
            do {
                while let data = try await input.read() {
                    try Task.checkCancellation()
                    // Pipe writes can block; keep them off the cooperative executor.
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                        inputQueue.async {
                            do {
                                try inputHandle.write(contentsOf: data)
                                continuation.resume()
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
            } catch where Task.isCancelled {
                // The client exited or the command was cancelled.
            } catch {
                inputError.setValue(error)
            }
        }
        defer {
            connection.close()
            inputTask.cancel()
            await inputTask.value
            await outputTask.value
            try? outputHandle.close()
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            for await _ in closed {}
            try Task.checkCancellation()
            if let error = inputError.value { throw error }
        } onCancel: {
            self.connection.close()
        }
    }
}
