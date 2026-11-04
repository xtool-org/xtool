import Testing
import XCLIUtils

struct ShutdownRegistryTests {
    @Test
    func concurrentShutdownRunsCleanupOnceInReverseOrder() async {
        let registry = ShutdownRegistry()
        let events = ShutdownEvents()
        registry.register { await events.append(1) }
        registry.register { await events.append(2) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { await registry.shutdown() } }
        }
        #expect(await events.values == [2, 1])
        await registry.shutdown()
        #expect(await events.values == [2, 1])
    }

    @Test
    func concurrentRegistrationsAreAllIncludedInShutdown() async {
        let registry = ShutdownRegistry()
        let events = ShutdownEvents()
        await withTaskGroup(of: Void.self) { group in
            for value in 0..<100 {
                group.addTask {
                    registry.register { await events.append(value) }
                }
            }
        }
        await registry.shutdown()
        #expect(await events.values.sorted() == Array(0..<100))
    }
}

private actor ShutdownEvents {
    var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}
