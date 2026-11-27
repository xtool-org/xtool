extension Sequence where Element: Sendable {
    /// Like `map`, but runs transformations concurrently.
    ///
    /// - Parameter maxConcurrency: The maximum number of transforms to run concurrently.
    /// If `nil`, we choose a reasonable default value. Use `.max` to run all at once.
    ///
    /// - Parameter transform: The transformation to apply to each element.
    ///
    /// - Returns: Transformed elements in the same order as the original sequence.
    public nonisolated(nonsending) func concurrentMap<T: Sendable, E: Error>(
        maxConcurrency: Int? = nil,
        _ transform: @escaping @Sendable @isolated(any) (Element) async throws(E) -> T,
    ) async throws(E) -> [T] {
        try await _concurrentMap(
            maxConcurrency: maxConcurrency ?? 10,
            transform,
            willWaitForNext: nil,
        )
    }

    nonisolated(nonsending) func _concurrentMap<T: Sendable, E: Error>(
        maxConcurrency: Int,
        _ transform: @escaping @Sendable @isolated(any) (Element) async throws(E) -> T,
        willWaitForNext: (() -> Void)?, // hook for testing
    ) async throws(E) -> [T] {
        precondition(maxConcurrency > 0, "maxConcurrency must be > 0")

        return try await withTaskGroup(of: (Int, Result<T, E>).self) { group -> Result<[T], E> in
            var results: [T?] = []
            results.reserveCapacity(self.underestimatedCount)
            var iterator = makeIterator()
            var exhausted = false
            var inFlight = 0
            while true {
                while !exhausted && inFlight < maxConcurrency {
                    guard let element = iterator.next() else {
                        exhausted = true
                        break
                    }
                    let index = results.count
                    results.append(nil)
                    group.addTask {
                        let result = await Result { () async throws(E) in
                            try await transform(element)
                        }
                        return (index, result)
                    }
                    inFlight += 1
                }
                willWaitForNext?()
                guard let (index, result) = await group.next() else { break }
                inFlight -= 1
                switch result {
                case .success(let value):
                    results[index] = value
                case .failure(let error):
                    group.cancelAll()
                    return .failure(error)
                }
            }
            // we can't use `as! [T]` because it breaks nested optionals (Foo??)
            return .success(results.map { $0! })
        }
        .get()
    }
}
