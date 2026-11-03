// swiftlint:disable all

#if os(Linux)

// https://github.com/sersoft-gmbh/swift-inotify

import Foundation
import CFileSystemMonitoring
import XUtils

extension FileSystemMonitor {
    public static let liveValue = FileSystemMonitor { directory in
        let notifier = try Inotifier()
        let events = try await notifier.events(for: directory)
            .compactMap { $0.path.map { FileSystemChangeEvent(file: $0) } }
            .eraseToStream()
        return FileSystemEvents {
            _ = notifier
            return events.makeAsyncIterator()
        }
    }
}

/// The notifier object.
final actor Inotifier {
    /// An asynchronous sequence of events for a certain file path.
    struct PathEvents: AsyncSequence, Sendable {
        @usableFromInline
        let stream: AsyncStream<InotifyEvent>

        @usableFromInline
        init(stream: AsyncStream<InotifyEvent>)  {
            self.stream = stream
        }

        @inlinable
        func makeAsyncIterator() -> AsyncStream<InotifyEvent>.AsyncIterator {
            stream.makeAsyncIterator()
        }
    }

    private let fileDescriptor: FileDescriptor
    private var streamTask: Task<Void, Never>?
    private var watches = Dictionary<CInt, Dictionary<UUID, AsyncStream<InotifyEvent>.Continuation>>()

    /// Creates a new instance.
    init() throws {
        guard case let fd = inotify_init1(0), fd != -1 else { throw Errno(rawValue: errno) }
        fileDescriptor = .init(rawValue: fd)
    }

    deinit {
        streamTask?.cancel()
        streamTask = nil
        try? fileDescriptor.close()
    }

    /// Closes this inotify instance. All further calls to this instance will fail.
    func close() throws {
        stopStreaming()
        try fileDescriptor.close()
    }

    /// Returns the asynchronous events sequence for the given file path.
    /// - Parameters:
    ///   - filePath: The file path to watch.
    /// - Returns: The asynchronous sequence of events for the given file path.
    func events(for filePath: FilePath) throws -> PathEvents {
        let wd = filePath.withCString {
            inotify_add_watch(fileDescriptor.rawValue, $0, cin_all_events)
        }
        guard wd != -1 else { throw Errno(rawValue: errno) }
        if streamTask == nil {
            startStreaming()
        }
        let stream = AsyncStream<InotifyEvent> { continuation in
            let sequenceID = UUID()
            watches[wd, default: [:]][sequenceID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    try? await self?.removeWatch(forDescriptor: wd, sequenceID: sequenceID)
                }
            }
        }
        return PathEvents(stream: stream)
    }

    private func startStreaming(restart: Bool = false) {
        assert(restart || streamTask == nil)
        if restart {
            streamTask?.cancel()
        }
        streamTask = Task { @concurrent [fileDescriptor, weak self] in
            do {
                for try await event in FileStream<inotify_event>(fileDescriptor: fileDescriptor) {
                    guard !Task.isCancelled, let self else { return }
                    await self.handle(event)
                }
            } catch where Task.isCancelled {
            } catch {
                // restart
                await self?.startStreaming(restart: true)
            }
        }
    }

    private func handle(_ cEvent: inotify_event) {
        guard var watchesToNotify = watches[cEvent.wd] else { return }
        defer {
            if watchesToNotify.isEmpty {
                watches.removeValue(forKey: cEvent.wd)
            } else {
                watches[cEvent.wd] = watchesToNotify
            }
        }
        // FIXME: Deal with connected events using `event.cookie`.
        let event = InotifyEvent(cEvent: cEvent)
        for (watchID, continuation) in watchesToNotify {
            if case .terminated = continuation.yield(event) {
                watchesToNotify.removeValue(forKey: watchID)
            }
        }
    }

    private func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
    }

    private func removeWatch(forDescriptor wd: CInt, sequenceID: UUID) throws {
        let status = inotify_rm_watch(fileDescriptor.rawValue, wd)
        guard status != -1 else { throw Errno(rawValue: errno) }
        guard var watchSequences = watches[wd] else { return }
        watchSequences.removeValue(forKey: sequenceID)
        guard watchSequences.isEmpty else { return }
        watches.removeValue(forKey: wd)
        guard watches.isEmpty else { return }
        stopStreaming()
    }
}

/// An event sent by inotify.
struct InotifyEvent: Equatable, Sendable {
    /// The file path of the event. If nil, the event is not for a file inside of the watch.
    let path: FilePath?
    /// The flags of the event.
    let flags: Flags

    init(cEvent event: inotify_event) {
        path = withUnsafePointer(to: event) {
            cin_event_name($0).map { FilePath(platformString: $0) }
        }
        flags = .init(rawValue: event.mask)
    }
}

extension InotifyEvent {
    /// A set of flags that can be set on an event.
    struct Flags: OptionSet, Hashable, Sendable {
        typealias RawValue = UInt32

        let rawValue: RawValue

        init(rawValue: RawValue) {
            self.rawValue = rawValue
        }
    }
}

extension InotifyEvent.Flags {
    /// File was accessed.
    static let accessed = InotifyEvent.Flags(rawValue: numericCast(IN_ACCESS))
    /// File was modified.
    static let modified = InotifyEvent.Flags(rawValue: numericCast(IN_MODIFY))
    /// Metadata changed.
    static let attributesChanged = InotifyEvent.Flags(rawValue: numericCast(IN_ATTRIB))
    /// A writeable file was closed.
    static let writableFileClosed = InotifyEvent.Flags(rawValue: numericCast(IN_CLOSE_WRITE))
    /// A non-writable file was closed.
    static let nonWritableFileClosed = InotifyEvent.Flags(rawValue: numericCast(IN_CLOSE_NOWRITE))
    /// File was opened.
    static let opened = InotifyEvent.Flags(rawValue: numericCast(IN_OPEN))
    /// File was moved from X.
    static let movedFrom = InotifyEvent.Flags(rawValue: numericCast(IN_MOVED_FROM))
    /// File was moved to Y.
    static let movedTo = InotifyEvent.Flags(rawValue: numericCast(IN_MOVED_TO))
    /// File was created inside the watched path.
    static let fileCreated = InotifyEvent.Flags(rawValue: numericCast(IN_CREATE))
    /// File was deleted inside the watched path.
    static let fileDeleted = InotifyEvent.Flags(rawValue: numericCast(IN_DELETE))
    /// The watched path was deleted.
    static let selfDeleted = InotifyEvent.Flags(rawValue: numericCast(IN_DELETE_SELF))
    /// The watched path was moved.
    static let selfMoved = InotifyEvent.Flags(rawValue: numericCast(IN_MOVE_SELF))

    /// Event occurred against a directory.
    static let isDirectory = InotifyEvent.Flags(rawValue: numericCast(IN_ISDIR))
}

/// An async sequence that continously streams the generic `Element` type from a given file.
/// The `Failure` type describes the errors thrown for the sequence. The ``FailureBehavior`` is used to handle errors.
struct FileStream<Element>: AsyncSequence {
    @usableFromInline
    let _stream: AsyncThrowingStream<Element, Error>

    /// Creates a new file stream for the given `fileDescriptor`.
    /// The `failureBehavior` defines how errors are handled.
    /// - Parameters:
    ///   - fileDescriptor: The file descriptor to stream from.
    ///   - failureBehavior: How to handle failures of the underlying stream.
    init(fileDescriptor: FileDescriptor) {
        _stream = .init(Element.self, { Self._gcdImplementation(for: fileDescriptor, using: $0) })
    }

    @inlinable
    func makeAsyncIterator() -> AsyncThrowingStream<Element, Error>.AsyncIterator {
        _stream.makeAsyncIterator()
    }
}

extension FileStream: Sendable where Element: Sendable {}

extension FileStream {
    private static func _gcdImplementation(for fileDescriptor: FileDescriptor,
                                           using cont: AsyncThrowingStream<Element, Error>.Continuation) {
        let source = _inactiveSource(from: fileDescriptor) {
            cont.yield($0)
        } onFailure: {
            cont.finish(throwing: $0)
        }
        cont.onTermination = { _ in source.cancel() }
        source.activate()
    }
}

fileprivate struct SendableDispatchSource: @unchecked Sendable {
    let source: any DispatchSourceRead

    func activate() {
        source.activate()
    }

    func cancel() {
        source.cancel()
    }
}

extension FileStream {
    private static func _inactiveSource(
        from fileDesc: FileDescriptor,
        onElement elementCallback: @escaping @Sendable (sending Element) -> (),
        onFailure failureCallback: @escaping @Sendable (any Error) -> ()
    ) -> SendableDispatchSource {
        let unsafeCallback = unsafeBitCast(elementCallback, to: (@Sendable (Element) -> ()).self)
        @Sendable
        func send(_ value: Element) {
            unsafeCallback(value)
        }

        let workerQueue = DispatchQueue(label: "de.sersoft.filestreamer.filestream.gcd.worker")
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDesc.rawValue, queue: workerQueue)
        let rawSize = MemoryLayout<Element>.size
        let rawSize64 = UInt64(rawSize)
        var remainingData: UInt64 = 0
        source.setEventHandler {
            do {
                remainingData += .init(source.data)
                guard case let capacity = remainingData / rawSize64, capacity > 0 else { return }
                let buffer = UnsafeMutableBufferPointer<Element>.allocate(capacity: .init(capacity))
                defer { buffer.deallocate() }
                let bytesRead = try fileDesc.read(into: UnsafeMutableRawBufferPointer(buffer))
                if case let noOfValues = bytesRead / rawSize, noOfValues > 0 {
                    for value in buffer.prefix(noOfValues) {
                        send(value)
                    }
                }
                let leftOverBytes = bytesRead % rawSize
                remainingData -= .init(bytesRead - leftOverBytes)
                if leftOverBytes > 0 {
                    do {
                        try fileDesc.seek(offset: .init(-leftOverBytes), from: .current)
                    } catch {
                        // If we failed to seek, we need to drop the left-over bytes.
                        remainingData -= .init(leftOverBytes)
                        throw error // Re-throw to land it in the failureCallback below
                    }
                }
            } catch {
                failureCallback(error)
            }
        }
        return .init(source: source)
    }
}

#endif
