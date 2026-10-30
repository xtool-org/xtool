import Testing
import XUtils

@Suite(.timeLimit(.minutes(1)))
struct ConcurrentMapTests {
    @Test(arguments: [[], [7], [3, 1, 3, 2], Array(0..<10)])
    func nonThrowingTransform(input: [Int]) async {
        // No `try` is needed when the transform cannot throw.
        let result = await input.concurrentMap { String($0 * 2) }
        #expect(result == input.map { String($0 * 2) })
    }

    @Test func emptyInputDoesNotCallTransform() async throws {
        let result = try await [Int]().concurrentMap { _ throws(MapError) -> Int in
            Issue.record("An empty sequence must not invoke the transform")
            throw .failed(0)
        }
        #expect(result.isEmpty)
    }

    @Test func singlePassSequence() async {
        var next = 0
        let input = AnySequence(AnyIterator<Int> {
            defer { next += 1 }
            return next < 4 ? next : nil
        })
        #expect(input.underestimatedCount == 0)

        let result = await input.concurrentMap { $0 * 2 }

        #expect(result == [0, 2, 4, 6])
    }

    @Test func optionalResults() async {
        let result = await (0..<4).concurrentMap { value -> Int? in
            value.isMultiple(of: 2) ? nil : value
        }
        #expect(result == [nil, 1, nil, 3])
    }

    @Test func nestedOptionalResults() async {
        let input: [Int??] = [.none, .some(.none), .some(.some(3))]
        let result = await input.concurrentMap { $0 }
        #expect(result == input)
    }

    @Test func concurrentExecutionPreservesInputOrder() async {
        let started = AsyncStream<Int>.makeStream()
        let finished = AsyncStream<Int>.makeStream()
        let gates = (0..<4).map { _ in AsyncStream<Void>.makeStream() }
        let task = Task {
            await (0..<4).concurrentMap { value in
                started.continuation.yield(value)
                for await _ in gates[value].stream {}
                finished.continuation.yield(value)
                return value * 2
            }
        }
        defer { task.cancel() }

        // Every transform must start before any is allowed to finish.
        var starts = started.stream.makeAsyncIterator()
        var startedValues: [Int] = []
        for _ in 0..<4 {
            if let value = await starts.next() {
                startedValues.append(value)
            }
        }
        #expect(startedValues.sorted() == [0, 1, 2, 3])

        // Let transforms finish in reverse order, independently of scheduler timing.
        var finishes = finished.stream.makeAsyncIterator()
        for value in (0..<4).reversed() {
            gates[value].continuation.finish()
            #expect(await finishes.next() == value)
        }
        #expect(await task.value == [0, 2, 4, 6])
    }

    @Test func preservesTypedError() async {
        // This signature also checks that concurrentMap preserves the error type.
        func map() async throws(MapError) -> [Int] {
            try await [42].concurrentMap { value throws(MapError) -> Int in
                throw .failed(value)
            }
        }

        await #expect(throws: MapError.failed(42)) {
            try await map()
        }
    }

    @Test func failureCancelsUnfinishedTransforms() async {
        let started = AsyncStream<Int>.makeStream()
        let failureGate = AsyncStream<Void>.makeStream()
        let siblingGate = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Int>.makeStream()
        let task = Task {
            try await (0..<3).concurrentMap { value async throws(MapError) -> Int in
                started.continuation.yield(value)
                if value == 1 {
                    for await _ in failureGate.stream {}
                    throw .failed(value)
                }
                // This stream only finishes when the task is cancelled.
                for await _ in siblingGate.stream {}
                #expect(Task.isCancelled)
                cancelled.continuation.yield(value)
                return value
            }
        }
        defer { task.cancel() }

        var starts = started.stream.makeAsyncIterator()
        for _ in 0..<3 {
            _ = await starts.next()
        }
        failureGate.continuation.finish()

        await #expect(throws: MapError.failed(1)) {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                // Let the suite's time limit break a regression in sibling cancellation.
                task.cancel()
            }
        }
        // The task group must wait for both cancelled transforms to exit.
        cancelled.continuation.finish()
        var cancelledValues: [Int] = []
        for await value in cancelled.stream {
            cancelledValues.append(value)
        }
        #expect(cancelledValues.sorted() == [0, 2])
    }

    @Test func parentCancellationReachesTransforms() async {
        let started = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            try await [1].concurrentMap { _ in
                started.continuation.yield(())
                for await _ in gate.stream {}
                try Task.checkCancellation()
            }
        }
        defer { task.cancel() }

        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private enum MapError: Error, Equatable {
        case failed(Int)
    }
}
