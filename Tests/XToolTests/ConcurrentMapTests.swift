import Testing
@testable import XUtils

@Suite(.timeLimit(.minutes(1)))
struct ConcurrentMapTests {
    @Test(arguments: [[], [7], [3, 1, 3, 2], Array(0..<10)], [nil, 1, 2, Int.max] as [Int?])
    func nonThrowingTransform(input: [Int], maxConcurrency: Int?) async {
        // No `try` is needed when the transform cannot throw.
        let result = await input.concurrentMap(maxConcurrency: maxConcurrency) { String($0 * 2) }
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

        let result = await input.concurrentMap(maxConcurrency: 1) { $0 * 2 }

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

    @Test(arguments: [2, 4, Int.max])
    func concurrentExecutionPreservesInputOrder(maxConcurrency: Int) async {
        let started = AsyncStream<Int>.makeStream()
        let finished = AsyncStream<Int>.makeStream()
        let gates = (0..<4).map { _ in AsyncStream<Void>.makeStream() }
        let task = Task {
            await (0..<4).concurrentMap(maxConcurrency: maxConcurrency) { value in
                started.continuation.yield(value)
                for await _ in gates[value].stream {}
                finished.continuation.yield(value)
                return value * 2
            }
        }
        defer { task.cancel() }

        // Fill the concurrency window before allowing any transform to finish.
        let initialCount = min(maxConcurrency, 4)
        var starts = started.stream.makeAsyncIterator()
        var startedValues: [Int] = []
        for _ in 0..<initialCount {
            if let value = await starts.next() {
                startedValues.append(value)
            }
        }
        #expect(startedValues.sorted() == Array(0..<initialCount))

        // Finish the newest transform first, keeping the first one suspended while work is replenished.
        var finishes = finished.stream.makeAsyncIterator()
        var pending = Set(startedValues)
        var next = initialCount
        while let value = pending.max() {
            pending.remove(value)
            gates[value].continuation.finish()
            #expect(await finishes.next() == value)
            if next < 4 {
                #expect(await starts.next() == next)
                pending.insert(next)
                next += 1
            }
        }
        #expect(await task.value == [0, 2, 4, 6])
    }

    @Test(arguments: [1, 2, 3, 25, 100, Int.max])
    func limitsConcurrentTransforms(maxConcurrency: Int) async {
        let checkpoints = AsyncStream<Int>.makeStream()
        let gates = (0..<25).map { _ in AsyncStream<Void>.makeStream() }
        let task = Task {
            // Both closures below run in the producer task. Only immutable snapshots
            // cross to the test through the checkpoint stream.
            var submitted = 0
            let input = AnySequence(AnyIterator<Int> {
                guard submitted < gates.count else { return nil }
                defer { submitted += 1 }
                return submitted
            })
            return await input._concurrentMap(maxConcurrency: maxConcurrency) { value in
                for await _ in gates[value].stream {}
                return value * 2
            } willWaitForNext: {
                checkpoints.continuation.yield(submitted)
            }
        }
        defer { task.cancel() }

        // No transform can finish yet. The hook proves submission has reached
        // group.next(), rather than merely being paused by the scheduler.
        let initialCount = min(maxConcurrency, gates.count)
        var waits = checkpoints.stream.makeAsyncIterator()
        #expect(await waits.next() == initialCount)

        // Each completed transform frees exactly one slot. Check the next submission
        // boundary before releasing another transform, including while draining.
        for value in gates.indices {
            gates[value].continuation.finish()
            #expect(await waits.next() == min(initialCount + value + 1, gates.count))
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        #expect(result == (0..<25).map { $0 * 2 })
    }

    @Test @MainActor func actorIsolatedTransform() async {
        var visited: [Int] = []
        let result = await (0..<4).concurrentMap(maxConcurrency: 2) { @MainActor value in
            MainActor.assertIsolated()
            visited.append(value)
            return value * 2
        }

        #expect(visited.sorted() == [0, 1, 2, 3])
        #expect(result == [0, 2, 4, 6])
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
            try await (0..<10).concurrentMap(maxConcurrency: 3) { value async throws(MapError) -> Int in
                #expect(value < 3, "A failure must not schedule the remaining inputs")
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
