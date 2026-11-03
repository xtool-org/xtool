import Dependencies
import XUtils

public struct FileSystemMonitor: Sendable {
    public var watch: @Sendable (_ directory: FilePath) async throws -> FileSystemEvents

    public init(
        watch: @Sendable @escaping (_ directory: FilePath) async throws -> FileSystemEvents,
    ) {
        self.watch = watch
    }
}

public struct FileSystemChangeEvent: Sendable, Hashable {
    public var file: FilePath

    public init(file: FilePath) {
        self.file = file
    }
}

extension FileSystemMonitor: TestDependencyKey {
    public static let testValue = FileSystemMonitor(
        watch: unimplemented(),
    )
}

extension DependencyValues {
    public var fileSystemMonitor: FileSystemMonitor {
        get { self[FileSystemMonitor.self] }
        set { self[FileSystemMonitor.self] = newValue }
    }
}

public struct FileSystemEvents: AsyncSequence, Sendable {
    private let makeIterator: @Sendable () -> AsyncStream<FileSystemChangeEvent>.AsyncIterator

    public init(
        makeAsyncIterator: @Sendable @escaping () -> AsyncStream<FileSystemChangeEvent>.AsyncIterator
    ) {
        self.makeIterator = makeAsyncIterator
    }

    public func makeAsyncIterator() -> AsyncStream<FileSystemChangeEvent>.AsyncIterator {
        makeIterator()
    }
}
