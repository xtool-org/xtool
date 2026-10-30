extension Sequence where Element: Sendable {
    public nonisolated(nonsending) func concurrentMap<T: Sendable, E: Error>(
        _ transform: @escaping @Sendable @isolated(any) (Element) async throws(E) -> T
    ) async throws(E) -> [T] {
        try await withTaskGroup(of: (Int, Result<T, E>).self) { group -> Result<[T], E> in
            var results: [T?] = []
            results.reserveCapacity(self.underestimatedCount)
            for (index, element) in enumerated() {
                group.addTask {
                    let result = await Result { () async throws(E) in
                        try await transform(element)
                    }
                    return (index, result)
                }
                results.append(nil)
            }
            for await (index, result) in group {
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
