// swiftlint:disable all

import Dependencies
import XUtils

struct FileSystemMonitor: Sendable {
    var watch: @Sendable (_ directory: FilePath) async throws -> FileSystemEvents
}

struct FileSystemChangeEvent: Sendable, Hashable {
    let file: FilePath
}

extension FileSystemMonitor: TestDependencyKey {
    static let testValue = FileSystemMonitor(
        watch: unimplemented(),
    )
}

extension DependencyValues {
    var fileSystemMonitor: FileSystemMonitor {
        get { self[FileSystemMonitor.self] }
        set { self[FileSystemMonitor.self] = newValue }
    }
}

struct FileSystemEvents: AsyncSequence, Sendable {
    private let makeIterator: @Sendable () -> AsyncStream<FileSystemChangeEvent>.AsyncIterator

    init(
        makeAsyncIterator: @Sendable @escaping () -> AsyncStream<FileSystemChangeEvent>.AsyncIterator
    ) {
        self.makeIterator = makeAsyncIterator
    }

    func makeAsyncIterator() -> AsyncStream<FileSystemChangeEvent>.AsyncIterator {
        makeIterator()
    }
}

#if os(macOS)

// https://github.com/jgvanwyk/SwiftFileSystemEvents

import Foundation
import CoreServices.FSEvents

extension FileSystemMonitor: DependencyKey {
    static let liveValue = FileSystemMonitor { directory in
        guard let url = URL(filePath: directory) else {
            throw Console.Error("Could not start FS monitor: bad file path: \(directory)")
        }
        let (events, cont) = AsyncStream<FileSystemChangeEvent>.makeStream()
        let stream = FileSystemEventStream(
            directoriesToWatch: [url],
            flags: .fileEvents,
            handler: {
                guard let file = FilePath($0.url) else { return }
                cont.yield(.init(file: file))
            }
        )
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
    
    private var streamRef: FSEventStreamRef! // Will be non-nil after initialisation completes.
    private let handler: (FileSystemEvent) -> Void
    
    /// Creates a new file system event stream with the given parameters.
    ///
    /// This calls `FSEventStreamCreate(_:_:_:_:_:_:_:)`.
    ///
    /// - Parameters:
    ///   - directoriesToWatch: An array of URLs representing the directories you wish to
    ///     monitor.
    ///   - sinceWhen: The service will supply events that have happened after the given
    ///     event ID. To ask for events since now pass ``FileSystemEvent/ID-swift.struct/now``.
    ///     Defaults to ``FileSystemEvent/ID-swift.struct/now``.
    ///   - latency: The number of seconds the service should wait after hearing about an
    ///     event from the kernel before passing it to the handler. Specifying a larger
    ///     value may result in more effective temporal coalescing, resulting in fewer
    ///     callbacks and greater overall efficiency. Defaults to 0.
    ///   - flags: Flags that modify the behaviour of the stream being created. See
    ///     ``FileSystemEventStream/Flags``. Defaults to `[]`.
    ///   - handler: A block that will be called on each event that occurs in the
    ///     directories being monitored.
    @available(macOS 10.5, *)
    init(directoriesToWatch: [URL],
                sinceWhen: FileSystemEvent.ID = .now,
                latency: TimeInterval = 0,
                flags: Flags = [],
                handler: @escaping (FileSystemEvent) -> Void) {
        self.handler = handler
        let pathsToWatch: CFArray
        if #available(macOS 13.0, *) {
            pathsToWatch = directoriesToWatch.map { $0.path(percentEncoded: false) } as CFArray
        } else {
            pathsToWatch = directoriesToWatch.map { $0.path } as CFArray
        }
        // We pass an unmanaged pointer to `self` as context info to the stream.
        // `FileSystemEventStream.callback` uses this to call `handler` with each event.
        // As the memory for `self` is managed by Swift, we pass `nil` for both `retain`
        // and `release`.
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil,
                                           release: nil,
                                           copyDescription: nil)
        // While the return value of `FSEventStreamCreate` is imported in Swift as
        // `FSEventStreamRef?`, the documentation for `FSEventStreamCreate` asserts that
        // its return value will always be a valid `FSEventStreamRef`, so we unwrap the
        // return value here.
        self.streamRef = FSEventStreamCreate(kCFAllocatorDefault,
                                             Self.callback,
                                             &context,
                                             pathsToWatch,
                                             sinceWhen.rawValue,
                                             latency,
                                             flags.rawValue)!
    }
    
    deinit {
        FSEventStreamRelease(streamRef)
    }
    
    private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, eventIDs in
        guard let info = info else { return }
        let eventPaths = eventPaths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>.self)
        let stream = Unmanaged<FileSystemEventStream>.fromOpaque(info).takeUnretainedValue()
        for index in 0..<numEvents {
            let url = URL(fileURLWithFileSystemRepresentation: eventPaths[index],
                          isDirectory: true,
                          relativeTo: nil)
            let flags = FileSystemEvent.Flags(rawValue: eventFlags[index])
            let id = FileSystemEvent.ID(rawValue: eventIDs[index])
            let event = FileSystemEvent(url: url, id: id, flags: flags)
            stream.handler(event)
        }
    }
    
    /// Fetches the `sinceWhen` property of the stream.
    ///
    /// Upon receiving an event (and just before invoking the client's callback) this
    /// attribute is updated to the highest-numbered event ID mentioned in the event.
    ///
    /// This calls `FSEventStreamGetLatestEventId`.
    var latestEventID: FileSystemEvent.ID {
        FileSystemEvent.ID(rawValue: FSEventStreamGetLatestEventId(streamRef))
    }
    
    /// Fetches the directories supplied to the stream.
    ///
    /// This calls `FSEventStreamCopyPathsBeingWatched`.
    var directoriesBeingWatched: [URL] {
        // `FSEventStreamCopyPathsBeingWatched` returns a `CFArray` of `CFStringRef`, which
        // can always be converted to `[String]`.
        let paths = FSEventStreamCopyPathsBeingWatched(streamRef) as! [String]
        let urls: [URL]
        if #available(macOS 13.0, *) {
            urls = paths.map { URL(filePath: $0, directoryHint: .isDirectory) }
        } else {
            urls = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        return urls
    }
        
    /// Schedules the stream on the specified dispatch queue.
    ///
    /// The caller is responsible for ensuring that the stream is scheduled on a dispatch
    /// queue and that the queue is started. If there is a problem scheduling the stream
    /// on the queue an error will be returned when you try to start the stream. To start
    /// receiving events on the stream, call ``FileSystemEventStream/start()``. To remove
    /// the stream from the queue on which it was scheduled, call
    /// ``FileSystemEventStream/setDispatchQueue(_:)`` with a `nil` queue parameter or
    /// call ``FileSystemEventStream/invalidate()`` which will do the same thing.
    ///
    /// Note: you must eventually call ``FileSystemEventStream/invalidate()``, and it is
    /// an error to call ``FileSystemEventStream/invalidate()`` without having the stream
    /// either scheduled on a dispatch queue, so do not set the dispatch queue to `nil`
    /// before calling ``FileSystemEventStream/invalidate()``.
    ///
    /// This calls `FSEventStreamSetDispatchQueue(_:,_:)`.
    ///
    /// - Parameters:
    ///   - dispatchQueue: The dispatch queue to use to receive events (or `nil` to stop
    ///     receiving events from the stream).
    @available(macOS 10.6, *)
    func setDispatchQueue(_ dispatchQueue: DispatchQueue?) {
        FSEventStreamSetDispatchQueue(streamRef, dispatchQueue)
    }
  
    /// Invalidate the stream.
    ///
    /// The stream will be unscheduled on any dispatch queue on which it has been scheduled.
    /// This may only be called if the stream has been scheduled on a dispatch queue with
    /// ``FileSystemEventStream/setDispatchQueue(_:)``.
    ///
    /// This calls `FSEventStreamInvalidate(_:)`.
    @available(macOS 10.5, *)
    func invalidate() {
        FSEventStreamInvalidate(streamRef)
    }
    
    /// Start the stream.
    ///
    /// Attempts to register with the File System Events service to receive events per the
    /// parameters in the stream. This can only be called once the stream has been
    /// scheduled on a dispatch queue. Once started, the stream can be stopped with
    /// ``FileSystemEventStream/stop()``.
    ///
    /// This ought to always succeed, but if it does not, you should have appropriate
    /// fallback in place.
    ///
    /// This calls `FSEventStreamStart(_:)`.
    ///
    /// - Throws:
    ///   - ``Error/couldNotStartStream`` if the stream could not be started.
    @available(macOS 10.5, *)
    func start() throws {
        guard FSEventStreamStart(streamRef) else { throw Error.couldNotStartStream }
    }
    
    /// Asks the File System Events service to flush out any events that have occurred but
    /// have not yet been delivered.
    ///
    /// Events may be delayed due to the latency parameter that was supplied when the stream
    /// was created. This flushing occurs asynchronously -- do not expect the events to have
    /// already been delivered by the time this call returns.
    ///
    /// This may only be called after you have started the stream with ``start()``.
    ///
    /// This calls `FSEventStreamFlushAsync(_:)`.
    ///
    /// - Returns: The largest event ID of any event ever queued for this stream, otherwise
    ///   zero if no events have been queued for this stream.
    @available(macOS 10.5, *)
    func flushAsync() -> FileSystemEvent.ID {
        FileSystemEvent.ID(rawValue: FSEventStreamFlushAsync(streamRef))
    }
    
    /// Asks the File System Events service to flush out any events that have occurred
    /// but have not yet been delivered.
    ///
    /// Events may be delayed due to the latency parameter that was supplied when the stream
    /// was created. This flushing occurs synchronously -- by the time this call returns,
    /// your handler will have been invoked for every event that had already/ occurred at
    /// the time you made this call.
    ///
    /// This may only be called after you have started the stream with ``start()``.
    ///
    /// This calls `FSEventStreamFlushSync(_:)`.
    @available(macOS 10.5, *)
    func flushSync() {
        FSEventStreamFlushSync(streamRef)
    }
    
    /// Unregisters with the File System Events service.
    ///
    /// Your handler will not be called for this stream while it is stopped. This can only
    /// be called if the stream has been started via ``FileSystemEventStream/start()``.
    /// Once stopped, the stream can be restarted via ``FileSystemEventStream/start()``, at
    /// which point it will resume receiving events from where it left off ("sinceWhen").
    ///
    /// This calls `FSEventStreamStop(_:)`.
    @available(macOS 10.5, *)
    func stop() {
        FSEventStreamStop(streamRef)
    }
    
    /// Prints a description of the supplied stream to stderr.
    ///
    /// For debugging only.
    ///
    /// This calls `FSEventStreamShow()`.
    @available(macOS 10.5, *)
    func show() {
        FSEventStreamShow(streamRef)
    }
    
    /// Sets directories to be filtered from the event stream.
    ///
    /// A maximum of eight directories may be specified.
    ///
    /// This calls `FSEventStreamSetExclusionPaths(_:,_:)`.
    @available(macOS 10.9, *)
    func setExclusionDirectories(_ directoryURLs: [URL]) throws {
        let paths: CFArray
        if #available(macOS 13.0, *) {
            paths = directoryURLs.map { $0.path(percentEncoded: false) } as CFArray
        } else {
            paths = directoryURLs.map { $0.path } as CFArray
        }
        guard FSEventStreamSetExclusionPaths(streamRef, paths) else { throw Error.couldNotExcludeDirectories }
    }
    
    /// Errors that may be thrown by ``FileSystemEventStream`` methods.
    enum Error: Swift.Error {
        /// Thrown by ``FileSystemEventStream/start()`` if the stream could not be
        /// started.
        case couldNotStartStream
        case couldNotExcludeDirectories
    }
    
    /// Flags that can be passed to the file system event stream to modify its behaviour.
    ///
    /// This wraps `FSEventStreamCreateFlags`.
    struct Flags: OptionSet, Sendable {
        let rawValue: FSEventStreamCreateFlags
        
        init(rawValue: FSEventStreamCreateFlags) {
            self.rawValue = rawValue
        }
        
        /// The default.
        ///
        /// This wraps `kFSEventStreamCreateFlagNone`.
        static let none = Self.init(rawValue: FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        
        // static let useCFTypes = Self.init(rawValue: FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes))
                
        /// Change the meaning of the latency parameter.
        ///
        /// If you specify this flag and more than latency seconds have elapsed since the
        /// last event, your app will receive the event immediately. The delivery of the
        /// event resets the latency timer and any further events will be delivered after
        /// latency seconds have elapsed. This flag is useful for apps that are interactive
        /// and want to react immediately to changes but avoid getting swamped by
        /// notifications when changes are occurringin rapid succession. If you do not
        /// specify this flag, then when an event occurs after a period of no events, the
        /// latency timer is started. Any events that occur during the next latency seconds
        /// will be delivered as one group (including that first event). The delivery of the
        /// group of events resets the latency timer and any further events will be
        /// delivered after latency seconds. This is the default behavior and is more
        /// appropriate for background, daemon or batch processing apps.
        static let noDefer = Self.init(rawValue: FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        
        /// Request notifications of changes along the path to the directory or directories
        /// being watched.
        ///
        /// For example, with this flag, if you watch `/foo/bar` and it is renamed to
        /// `/foo/bar.old`, you would receive a RootChanged event. The same is true if the
        /// directory `/foo` were renamed. The event you receive is a special event: the URL
        /// for the event is the original URL you specified, the flag
        /// `FileSystemEvent.Flags.rootChanged` is set, and the event ID `FileSystemEvent.ID`
        /// is zero. RootChanged events are useful to indicate that you should rescan a
        /// particular hierarchy because it changed completely (as opposed to the things
        /// inside of it changing). If you want to track the current location of a directory,
        /// it is best to open the directory before creating the stream so that you have a
        /// file descriptor for it and can issue an `F_GETPATH` `fcntl()` to find the current
        /// path.
        static let watchRoot = Self.init(rawValue: FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot))
        
        /// Do not send events that were triggered by the current process.
        ///
        /// This is useful for reducing the volume of events that are sent. It is only
        /// useful if your process might modify the file system hierarchy beneath the
        /// path or paths being monitored. This has no effect on historical events, i.e.,
        /// those delivered before the HistoryDone sentinel event. Also, this does not apply
        /// to RootChanged events because the WatchRoot feature uses a separate mechanism
        /// that is unable to provide information about the responsible process.
        @available(macOS 10.6, *)
        static let ignoreSelf = Self.init(rawValue: FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf))
        
        /// Request file-level notifications.
        ///
        /// Your stream will receive events about individual files in the hierarchy you are
        /// watching instead of only receiving directory level notifications. Use this flag
        /// with care as it will generate significantly more events than without it.
        @available(macOS 10.7, *)
        static let fileEvents = Self.init(rawValue: FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
        
        /// Tag events that were triggered by the current process with the "OwnEvent" flag.
        ///
        /// This is only useful if your process might modify the file system hierarchy
        /// beneath the path(s) being monitored and you wish to know which events were
        /// triggered by your process. Note: this has no effect on historical events, i.e.,
        /// those delivered before the HistoryDone sentinel event.
        @available(macOS 10.9, *)
        static let markSelf = Self.init(rawValue: FSEventStreamCreateFlags(kFSEventStreamCreateFlagMarkSelf))
        
        // @available(macOS 10.13, *)
        // static let useExtendedData = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamCreateFlagUseExtendedData))
        
        /// Reguest full event history.
        ///
        /// When requesting historical events it is possible that some events may get
        /// skipped due to the way they are stored.  With this flag all historical events
        /// in a given chunk are returned even if their event ID is less than the
        /// `sinceWhen` ID.  Put another way, deliver all the events in the first chunk of
        /// historical events that contains the `sinceWhen` ID so that none are skipped even
        /// if their id is less than the `sinceWhen` ID.  This overlap avoids any issue with
        /// missing events that happened at/near the time of an unclean restart of the
        /// client process.
        @available(macOS 10.15, *)
        static let fullHistory = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamCreateFlagFullHistory))
    }
    
}

// MARK: FileSystemEvent

/// A file system event.
///
/// Whenever an event occurs in a directory being watched by
/// ``FileSystemEventStream``, the handler passed to the stream is called with a
/// ``FileSystemEvent`` encapsulating the event.
struct FileSystemEvent: Hashable, Sendable {
   
    /// The URL of the directory in which the event occured.
    let url: URL
    
    
    /// The ID for the event.
    let id: ID
    
    /// Flags set for the event.
    ///
    /// If no flags are set, then there was some change in the directory in which
    /// the event occured.
    let flags: Flags
    
    /// The ID of a file system event.
    ///
    /// This wraps `FSEventStreamID`. Each file system event has a unique ID. Event IDs
    /// all come from a single global source. They are monotonically increasing per
    /// system, even across reboots and drives coming and going. An event ID may be
    /// passed as the `sinceWhen` parameter to
    /// ``FileSystemEventStream/init(directoriesToWatch:sinceWhen:latency:flags:handler:)``
    /// to register the stream for notifications of all events after the event with the
    /// given ID.
    ///
    /// `FSEventStreamID` is just a `UInt64`, so integer wrapping may occur. See
    /// ``Flags-swift.struct/eventIdsWrapped``.
    struct ID: RawRepresentable, Hashable, Comparable, Sendable {
        let rawValue: FSEventStreamEventId
        
        static func < (lhs: FileSystemEvent.ID, rhs: FileSystemEvent.ID) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
        
        init(rawValue: FSEventStreamEventId) {
            self.rawValue = rawValue
        }
        
        static let zero = Self.init(rawValue: 0)
        
        /// A special event ID that may be passed as the `sinceWhen` parameter to
        /// ``FileSystemEventStream/init(directoriesToWatch:sinceWhen:latency:flags:handler:)``
        /// in order to receive notifications of all events "since now".
        static let now = Self.init(rawValue: FSEventStreamEventId(kFSEventStreamEventIdSinceNow))
        
        /// The most recently generated event ID.
        ///
        /// This fetches the most recently generated event ID, system-wide. By the time the ID is
        /// fetched, you have already received events with newer IDs.
        static var current: Self {
            Self.init(rawValue: FSEventsGetCurrentEventId())
        }
    }
    
    /// Possible flags for a file system event.
    ///
    /// This wraps `FSEventStreamEventFlags`.
    struct Flags: OptionSet, Hashable, Sendable {
        let rawValue: FSEventStreamEventFlags
        
        init(rawValue: FSEventStreamEventFlags) {
            self.rawValue = rawValue
        }
        
        /// There was some change in the directory at the specific URL supplied in this event.
        ///
        /// This wraps `kFSEventStreamEventFlagNone`.
        static let none = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagNone))
        
        /// Your application must rescan not just the directory given in the event, but all
        /// its children, recursively.
        ///
        /// This can happen if there was a problem whereby events were coalesced
        /// hierarchically. For example, an event in `/Users/jsmith/Music` and an event in
        /// `/Users/jsmith/Pictures` might be coalesced into an event with this flag set
        /// and path `/Users/jsmith`. If this flag is set you may be able to get an idea of
        /// whether the bottleneck happened in the kernel (less likely) or in your client
        /// (more likely) by checking for the presence of the informational flags
        /// `userDropped` or `kernelDropped`.
        ///
        /// This wraps `kFSEventStreamEventFlagMustScanSubDirs`.
        static let mustScanSubDirs = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs))

        /// A problem occured in buffering the event in user space.
        ///
        /// See ``mustScanSubDirs``.
        ///
        /// This wraps `kFSEventStreamEventFlagUserDropped`.
        static let userDropped = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped))
        
        /// A problem occured in buffering the event in kernel space.
        ///
        /// See ``mustScanSubDirs``.
        ///
        /// This wraps `kFSEventStreamEventFlagKernelDropped`.
        static let kernelDropped = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped))
        
        /// The 64-bit event ID counter wrapped around.
        ///
        /// If this flag is present, previously-issued event ID's are no longer valid
        /// values for the `sinceWhen` parameter to
        /// ``FileSystemEventStream/init(directoriesToWatch:sinceWhen:latency:flags:handler:)``.
        ///
        /// This wraps `kFSEventStreamEventFlagEventIdsWrapped`.
        static let eventIdsWrapped = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped))
        
        /// Marks a sentinel event sent to mark the end of the historical events.
        ///
        /// If a ``FileSystemEvent/ID-swift.struct`` was passed as the `sinceWhen` parameter
        /// to the call to
        /// ``FileSystemEventStream/init(directoriesToWatch:sinceWhen:latency:flags:handler:)``
        /// that created this stream, and this value was not
        /// ``FileSystemEvent/ID-swift.struct/now``, then the handler will be called with
        /// each event before `now` (the "historial events"). Once this is finised, the
        /// handler will be invoked with an event (the "history sentinel event") with this
        /// flag set. The URL provided with this event should be ignored.
        ///
        /// This wraps `kFSEventStreamEventFlagHistoryDone`.
        static let historyDone = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone))
        
        /// Marks a special event sent when there is a change to one of the directories
        /// along the path to one of the directories you asked to watch.
        ///
        /// When this flag is set, the event ID is zero and the path corresponds to one of
        /// the paths you asked to watch (specifically, the one that changed). The path may
        /// no longer exist because it or one of its parents was deleted or renamed. Events
        /// with this flag set will only be sent if you passed the
        /// ``FileSystemEventStream/Flags/watchRoot`` when creating the stream with
        /// ``FileSystemEventStream/init(directoriesToWatch:sinceWhen:latency:flags:handler:)``.
        ///
        /// This wraps `kFSEventStreamEventFlagRootChanged`.
        static let rootChanged = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged))
        
        /// Marks a special event sent when a volume is mounted underneath one of the paths
        /// being monitored.
        /// The `URL` represents the path to the newly-mounted volume. You will receive
        /// one of these notifications for every volume mount event inside the kernel
        /// (independent of DiskArbitration).
        ///
        /// This wraps `kFSEventStreamEventFlagMount`.
        static let mount = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagMount))
        
        /// Marks a special event sent when a volume is unmounted underneath one of the
        /// paths being monitored.
        ///
        /// The path in the event is the path to the directory from which the volume was
        /// unmounted. You will receive one of these notifications for every volume unmount
        /// event inside the kernel.
        ///
        /// This wraps `kFSEventStreamEventFlagUnmount`.
        static let unmount = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount))
        
        /// A file system object was created at the specific URL supplied in this event.
        ///
        /// This flag is only ever set if you specified the ``FileSystemEventStream/Flags/fileEvents``
        /// flag when creating the stream.
        ///
        /// This wraps `kFSEventStreamEventFlagItemCreated`.
        @available(macOS 10.7, *)
        static let itemCreated = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))
        
        /// A file system object was removed at the specific URL supplied in this event.
        ///
        /// This flag is only ever set if you specified the ``FileSystemEventStream/Flags/fileEvents``
        /// flag when creating the stream.
        ///
        /// This wraps `kFSEventStreamEventFlagItemRemoved`.
        @available(macOS 10.7, *)
        static let itemRemoved = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved))
        
        /// A file system object at the specific URL supplied in this event had its metadata modified.
        ///
        /// This flag is only ever set if you specified the ``FileSystemEventStream/Flags/fileEvents``
        /// flag when creating the stream.
        ///
        /// This wraps `kFSEventStreamEventFlagItemInodeMetaMod`.
        @available(macOS 10.7, *)
        static let itemInodeMetaMod = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagItemInodeMetaMod))
        
        /// A file system object was renamed at the specific URL supplied in this event.
        ///
        /// This flag is only ever set if you specified the ``FileSystemEventStream/Flags/fileEvents``
        /// flag when creating the stream.
        ///
        /// This wraps `kFSEventStreamEventFlagItemRenamed`.
        @available(macOS 10.7, *)
        static let itemRenamed = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed))
        
        /// A file system object at the specific URL supplied in this event had its data modified.
        ///
        /// This flag is only ever set if you specified the ``FileSystemEventStream/Flags/fileEvents``
        /// flag when creating the stream.
        ///
        /// This wraps `kFSEventStreamEventFlagItemModified`.
        @available(macOS 10.7, *)
        static let itemModified = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified))
        
        /// A file system object at the specific URL supplied in this event had its
        /// FinderInfo data modified.
        ///
        /// This flag is only ever set if you specified the ``FileSystemEventStream/Flags/fileEvents``
        /// flag when creating the stream.
        ///
        /// This wraps `kFSEventStreamEventFlagItemFinderInfoMod`.
        @available(macOS 10.7, *)
        static let itemFinderInfoMod = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagItemFinderInfoMod))
        
        /// A file system object at the specific URL supplied in this event had its
        /// ownership changed.
        ///
        /// This flag is only ever set if you specified the ``FileSystemEventStream/Flags/fileEvents``
        /// flag when creating the stream.
        ///
        /// This wraps `kFSEventStreamEventFlagItemChangeOwner`.
        @available(macOS 10.7, *)
        static let itemChangeOwner = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagItemChangeOwner))
        
        /// A file system object at the specific URL supplied in this event had its
        /// extended attributes modified.
        ///
        /// This flag is only ever set if you specified the ``FileSystemEventStream/Flags/fileEvents``
        /// flag when creating the stream.
        ///
        /// This wraps `kFSEventStreamEventFlagItemXattrMod`.
        @available(macOS 10.7, *)
        static let itemXattrMod = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagItemXattrMod))
        
        /// The file system object at the specific URL supplied in this event is a regular file.
        ///
        /// This flag is only ever set if you specified the ``FileSystemEventStream/Flags/fileEvents``
        /// flag when creating the stream.
        ///
        /// This wraps `kFSEventStreamEventFlagItemIsFile`.
        @available(macOS 10.7, *)
        static let itemIsFile = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile))
        
        /// The file system object at the specific URL supplied in this event is a directory.
        ///
        /// This flag is only ever set if you specified the ``FileSystemEventStream/Flags/fileEvents``
        /// flag when creating the stream.
        ///
        /// This wraps `kFSEventStreamEventFlagItemIsDir`.
        @available(macOS 10.7, *)
        static let itemIsDir = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir))
        
        /// The file system object at the specific URL supplied in this event is a symbolic link.
        ///
        /// This flag is only ever set if you specified the ``FileSystemEventStream/Flags/fileEvents``
        /// flag when creating the stream.
        ///
        /// This wraps `kFSEventStreamEventFlagItemIsSymlink`.
        @available(macOS 10.7, *)
        static let itemIsSymlink = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsSymlink))
        
        /// Indicates the event was triggered by the current process.
        ///
        /// This flag is only ever set if you specified the ``FileSystemEventStream/Flags/markSelf``
        /// flag when creating the stream.
        ///
        /// This wraps `kFSEventStreamEventFlagOwnEvent`.
        @available(macOS 10.9, *)
        static let ownEvent = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagOwnEvent))
        
        /// The file system object at the specific URL supplied in this event is a hard link.
        ///
        /// This flag is only ever set if you specified the ``FileSystemEventStream/Flags/fileEvents``
        /// flag when creating the stream.
        ///
        /// This wraps `kFSEventStreamEventFlagItemIsHardlink`.
        @available(macOS 10.10, *)
        static let itemIsHardlink = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsHardlink))
        
        /// The file system object at the specific URL supplied in this event was the last hard link.
        ///
        /// This flag is only ever set if you specified the ``FileSystemEventStream/Flags/fileEvents``
        /// flag when creating the stream.
        ///
        /// This wraps `kFSEventStreamEventFlagItemIsLastHardlink`.
        @available(macOS 10.10, *)
        static let itemIsLastHardlink = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsLastHardlink))
        
        /// The file system object at the specific path supplied in this event is a clone or was cloned.
        ///
        /// This flag is only ever set if you specified the ``FileSystemEventStream/Flags/fileEvents``
        /// flag when creating the stream.
        ///
        /// This wraps `kFSEventStreamEventFlagItemCloned`.
        @available(macOS 10.13, *)
        static let itemCloned = Self.init(rawValue: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCloned))
    }
    
}

#else

import Foundation
import XKit
import CXKit
import SystemPackage

// https://github.com/sersoft-gmbh/swift-inotify

extension FileSystemMonitor {
    static let liveValue = FileSystemMonitor { directory in
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
                    try await self?.removeWatch(forDescriptor: wd, sequenceID: sequenceID)
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
        streamTask = Task.detached { [fileDescriptor, weak self] in
            do {
                for try await event in FileStream<inotify_event>(fileDescriptor: fileDescriptor) {
                    guard !Task.isCancelled, let self else { return }
                    await self.handle(event)
                }
            } catch is CancellationError {
            } catch {
                print("[INOTIFY] Error: \(error)")
                print("[INOTIFY] Restarting stream...")
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

#if swift(>=6.2) && canImport(Darwin)
fileprivate typealias SendableDispatchSource = any DispatchSourceRead
#else
fileprivate struct SendableDispatchSource: @unchecked Sendable {
    let source: any DispatchSourceRead

    func activate() {
        source.activate()
    }

    func cancel() {
        source.cancel()
    }
}
#endif

extension FileStream {
    private static func _inactiveSource(from fileDesc: FileDescriptor,
                                        onElement elementCallback: @escaping @Sendable (sending Element) -> (),
                                        onFailure failureCallback: @escaping @Sendable (any Error) -> ()) -> SendableDispatchSource {
#if compiler(>=6.2)
        let unsafeCallback = unsafe unsafeBitCast(elementCallback, to: (@Sendable (Element) -> ()).self)
#else
        let unsafeCallback = unsafeBitCast(elementCallback, to: (@Sendable (Element) -> ()).self)
#endif
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
#if compiler(>=6.2)
                defer { unsafe buffer.deallocate() }
                let bytesRead = unsafe try fileDesc.read(into: UnsafeMutableRawBufferPointer(buffer))
#else
                defer { buffer.deallocate() }
                let bytesRead = try fileDesc.read(into: UnsafeMutableRawBufferPointer(buffer))
#endif
                if case let noOfValues = bytesRead / rawSize, noOfValues > 0 {
#if compiler(>=6.2)
                    for unsafe value in unsafe buffer.prefix(noOfValues) {
                        send(value)
                    }
#else
                    for value in buffer.prefix(noOfValues) {
                        send(value)
                    }
#endif
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
#if swift(>=6.2) && canImport(Darwin)
        return source
#else
        return .init(source: source)
#endif
    }
}

#endif
