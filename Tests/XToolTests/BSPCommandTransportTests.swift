import BuildServerProtocol
import Dependencies
import Foundation
import LanguageServerProtocol
import LanguageServerProtocolTransport
import Testing
import ToolsProtocolsSwiftExtensions
import XCLIUtils
import XUtils
@testable import XToolSupport

struct BSPCommandTransportTests {
    @Test(.timeLimit(.minutes(1)))
    func fragmentedInputAndOutputThroughCommandStreams() async throws {
        let input = DataChannel()
        let (output, continuation) = AsyncStream.makeStream(of: Data.self)
        let transport = withDependencies {
            $0.input = CommandInput(channel: input)
            $0.out.write = { data, stream, _ in
                #expect(stream == .stdout)
                continuation.yield(data)
            }
        } operation: { BSPCommandTransport() }
        let handler = TestBSPHandler(connection: transport.connection)
        let task = Task { try await transport.run(receiveHandler: handler) }
        let request = frame(#"{"jsonrpc":"2.0","id":1,"method":"build/shutdown"}"#)
        for byte in request { input.write(Data([byte])) }
        var received = Data()
        for await chunk in output {
            received.append(chunk)
            guard let separator = received.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let header = String(decoding: received[..<separator.lowerBound], as: UTF8.self)
            let length = try #require(Int(header.dropFirst("Content-Length: ".count)))
            let body = received[separator.upperBound...]
            guard body.count >= length else { continue }
            let response = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(response["id"] as? Int == 1)
            #expect(response["result"] != nil)
            break
        }
        input.write(frame(#"{"jsonrpc":"2.0","method":"build/exit"}"#))
        // BSP exit must finish even if the client's input stream remains open.
        try await task.value
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancellationUnblocksInput(beforeStart: Bool) async throws {
        let input = DataChannel()
        let (reading, continuation) = AsyncStream.makeStream(of: Never.self)
        let transport = withDependencies {
            $0.input = CommandInput(read: { limit in
                continuation.finish()
                return try await input.read(upTo: limit)
            })
            $0.out.write = { _, _, _ in Issue.record("Unexpected BSP output") }
        } operation: { BSPCommandTransport() }
        let task = Task {
            if beforeStart { withUnsafeCurrentTask { $0?.cancel() } }
            try await transport.run(receiveHandler: TestBSPHandler(connection: transport.connection))
        }
        if !beforeStart {
            for await _ in reading {}
            task.cancel()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(.timeLimit(.minutes(1)))
    func inputEOFAndErrorsCloseConnection() async throws {
        for fails in [false, true] {
            let transport = withDependencies {
                $0.input = CommandInput(read: { _ in
                    if fails { throw InputError() }
                    return nil
                })
                $0.out.write = { _, _, _ in Issue.record("Unexpected BSP output") }
            } operation: { BSPCommandTransport() }
            let handler = TestBSPHandler(connection: transport.connection)
            if fails {
                await #expect(throws: InputError.self) { try await transport.run(receiveHandler: handler) }
            } else {
                try await transport.run(receiveHandler: handler)
            }
        }
    }

    private struct InputError: Error {}

    private func frame(_ json: String) -> Data {
        Data("Content-Length: \(json.utf8.count)\r\n\r\n\(json)".utf8)
    }
}

private actor TestBSPHandler: QueueBasedMessageHandler {
    let messageHandlingHelper = QueueBasedMessageHandlerHelper(
        signpostLoggingCategory: "test-bsp-handler",
        createLoggingScope: false
    )
    let messageHandlingQueue = AsyncQueue<BuildServerMessageDependencyTracker>()
    let connection: JSONRPCConnection

    init(connection: JSONRPCConnection) { self.connection = connection }

    func handle(notification: some NotificationType) async {
        if notification is OnBuildExitNotification { connection.close() }
    }

    func handle<Request: RequestType>(
        request: Request,
        id: RequestID,
        reply: @escaping @Sendable (Result<Request.Response, any Error>) -> Void
    ) async {
        await RequestAndReply(request, reply: reply).reply {
            guard request is BuildShutdownRequest, let response = VoidResponse() as? Request.Response else {
                throw ResponseError.methodNotFound(Request.method)
            }
            return response
        }
    }
}
