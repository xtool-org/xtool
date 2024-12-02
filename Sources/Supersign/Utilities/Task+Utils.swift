extension Task<Never, Never> {
    public static func sleep(seconds: Double) async throws {
        try await sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
