import Testing
import XCLIUtils

struct ShutdownRegistryTests {
    @Test
    func concurrentShutdownRunsCleanupOnceInReverseOrder() async {
        let registry = ShutdownRegistry()
        let events = ShutdownEvents()
        await registry.register { await events.append(1) }
        await registry.register { await events.append(2) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { await registry.shutdown() } }
        }
        #expect(await events.values == [2, 1])
        await registry.shutdown()
        #expect(await events.values == [2, 1])
    }

    @Test
    func registrationAfterShutdownCleansUpImmediately() async {
        let registry = ShutdownRegistry()
        let events = ShutdownEvents()
        await registry.shutdown()
        await registry.register { await events.append(1) }
        #expect(await events.values == [1])
    }
}

private actor ShutdownEvents {
    var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}
