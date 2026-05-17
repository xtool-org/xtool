import Testing
import XUtils

@Suite("Diagnostics")
struct DiagnosticsTests {
    @Test("Drain returns appended entries and clears storage")
    func drainClears() async {
        let diag = Diagnostics()
        await diag.warn("first")
        await diag.note("second")
        let first = await diag.drain()
        #expect(first.count == 2)
        #expect(first[0].severity == .warning)
        #expect(first[1].severity == .note)
        let second = await diag.drain()
        #expect(second.isEmpty)
    }
}
