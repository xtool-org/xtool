import Foundation
import ConcurrencyExtras

public final class DispatchInput: Sendable {
    private struct State {
        var hasClosed = false
        var isReading = false
    }

    public static let defaultChunkSize: Int = 64 * 1024

    let queue = DispatchQueue(label: "xtool.dispatch-reader")
    let channel: DispatchIO
    let chunkSize: Int
    private let closeSignal: Task<Void, Never>
    private let dataChannel = DataChannel()
    private let state = LockIsolated(State())

    public init(fileDesciptor: FileDescriptor, chunkSize: Int = DispatchInput.defaultChunkSize) throws {
        let closeSignal = Task { _ = try? await Task.never() }
        self.closeSignal = closeSignal
        self.chunkSize = chunkSize

        enum InitState {
            case pending
            case done(onClose: @Sendable (Int32) -> Void)
            case failed(Int32)
        }
        let initState = LockIsolated<InitState>(.pending)
        self.channel = DispatchIO(
            type: .stream,
            fileDescriptor: fileDesciptor.rawValue,
            queue: queue,
        ) { err in
            initState.withValue { state in
                switch state {
                case .pending:
                    state = .failed(err)
                case .done(let onClose):
                    onClose(err)
                case .failed: // wat
                    break
                }
            }
        }
        channel.setLimit(lowWater: 1)

        try initState.withValue { state in
            switch state {
            case .pending:
                state = .done { [weak self] err in
                    self?.didClose(code: err)
                    closeSignal.cancel()
                }
            case .done: // wat
                break
            case .failed(let err):
                throw Errno(rawValue: err)
            }
        }

        dataChannel.onRequest { [weak self] in
            self?.onRequest()
        }
    }

    nonisolated(nonsending) public func read(upTo limit: DataChannel.Limit = .unlimited) async throws -> Data? {
        try await dataChannel.read(upTo: limit)
    }

    private func onRequest() {
        let didMarkStarted = state.withValue { state in
            guard !state.isReading else { return false }
            state.isReading = true
            return true
        }
        guard didMarkStarted else { return }
        channel.read(
            offset: 0,
            length: chunkSize,
            queue: queue,
        ) { [weak self] done, data, error in
            guard let self else { return }
            let data = data.map { Data($0) }
            self.onRead(
                done: done,
                data: data,
                error: error,
            )
        }
    }

    private func onRead(
        done: Bool,
        data: Data?,
        error: Int32,
    ) {
        if done {
            state.withValue { $0.isReading = false }
        }
        let data = data.map { Data($0) }
        if let data, !data.isEmpty {
            dataChannel.write(data)
        }
        if error != 0 {
            requestClose(error: Errno(rawValue: error))
        } else if done, data?.isEmpty == true {
            requestClose(error: nil)
        }
    }

    nonisolated(nonsending) public func close() async {
        requestClose(error: nil)
        await closeSignal.value
    }

    private func requestClose(error: Error?) {
        guard markClosedIfNeeded() else { return }
        channel.close(flags: .stop)
        dataChannel.finish(error: error)
    }

    private func didClose(code: Int32) {
        guard markClosedIfNeeded() else { return }
        dataChannel.finish(error: code == 0 ? nil : Errno(rawValue: code))
    }

    private func markClosedIfNeeded() -> Bool {
        state.withValue { state in
            let hadClosed = state.hasClosed
            state.hasClosed = true
            return !hadClosed
        }
    }

    deinit {
        guard !state.withValue(\.hasClosed) else { return }
        channel.close(flags: .stop)
        dataChannel.finish(error: nil)
    }
}
