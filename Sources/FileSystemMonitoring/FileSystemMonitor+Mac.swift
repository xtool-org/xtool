// swiftlint:disable all

#if os(macOS)

// https://github.com/jgvanwyk/SwiftFileSystemEvents

import Foundation
import CoreServices.FSEvents
import Dependencies
import XUtils

extension FileSystemMonitor: DependencyKey {
    public static let liveValue = FileSystemMonitor { directory in
        let (events, cont) = AsyncStream<FileSystemChangeEvent>.makeStream()
        let stream = FileSystemEventStream(directoriesToWatch: [directory]) {
            cont.yield(.init(file: $0))
        }
        let queue = DispatchQueue(label: "fsevents-queue")
        stream.setDispatchQueue(queue)
        try stream.start()
        cont.onTermination = { _ in
            stream.invalidate()
        }
        let onDeinit = OnDeinit { cont.finish() }
        return FileSystemEvents {
            _ = onDeinit
            return events.makeAsyncIterator()
        }
    }
}

private final class OnDeinit: Sendable {
    let perform: @Sendable () -> Void
    init(perform: @Sendable @escaping () -> Void) {
        self.perform = perform
    }
    deinit { perform() }
}

// MARK: FileSystemEventStream

/// Register for a stream of notifications of file system events in a list of directories.
final class FileSystemEventStream: @unchecked Sendable {

    private let streamRef: FSEventStreamRef
    private let handlerRef: AnyObject

    init(
        directoriesToWatch: [FilePath],
        handler: @escaping @Sendable (FilePath) -> Void
    ) {
        self.handlerRef = handler as AnyObject
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handlerRef).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        self.streamRef = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            directoriesToWatch.map { $0.string } as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents),
        )!
    }

    deinit {
        FSEventStreamRelease(streamRef)
    }

    private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
        guard let info = info else { return }
        let eventPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        // note: the cast must include @Sendable to match the stored closure's type
        guard let handler = Unmanaged<AnyObject>.fromOpaque(info).takeUnretainedValue()
            as? @Sendable (FilePath) -> Void else { return }
        for index in 0..<numEvents {
            handler(FilePath(platformString: eventPaths[index]))
        }
    }

    func setDispatchQueue(_ dispatchQueue: DispatchQueue?) {
        FSEventStreamSetDispatchQueue(streamRef, dispatchQueue)
    }

    func invalidate() {
        FSEventStreamInvalidate(streamRef)
    }

    func start() throws {
        guard FSEventStreamStart(streamRef) else { throw Error.couldNotStartStream }
    }

    enum Error: Swift.Error {
        case couldNotStartStream
    }
    
}

#endif
