import Dependencies
import Foundation
import XCLIUtils
import XUtils

enum XIPExtraction: Sendable {
    static let stallWarning: Duration = .seconds(45)
    static let stallTimeout: Duration = .seconds(300)

    struct Progress: Equatable, Sendable {
        var bytesRead: Int64
        var totalBytes: Int64
        var filesWritten: Int
        var lastChange: Duration
        var lastFreeBytes: Int64?

        var percent: Int {
            guard totalBytes > 0 else { return 0 }
            let value = Int((Double(bytesRead) / Double(totalBytes) * 100).rounded(.down))
            return min(100, max(0, value))
        }

        var statusLine: String {
            if filesWritten > 0 {
                "[Extracting XIP] \(percent)% (\(filesWritten) files)"
            } else {
                "[Extracting XIP] \(percent)%"
            }
        }

        func isStalled(at elapsed: Duration, timeout: Duration) -> Bool {
            elapsed - lastChange >= timeout
        }

        /// One large file can take minutes to write with no read or file event,
        /// so a drop in the destination's free space also counts as progress.
        /// Space being freed never does: extraction only consumes it.
        /// Returns whether this reading counted.
        @discardableResult
        mutating func noteFreeBytes(_ freeBytes: Int64, at elapsed: Duration) -> Bool {
            defer { lastFreeBytes = freeBytes }
            guard let lastFreeBytes, freeBytes < lastFreeBytes else { return false }
            lastChange = elapsed
            return true
        }
    }

    enum DiskSpace: Equatable, Sendable {
        case ok
        case warning(String)
        case error(String)

        static func evaluate(xipSize: Int64, freeBytes: Int64?, willStage: Bool = false) -> Self {
            guard let freeBytes else {
                return .warning("Warning: could not measure free disk space on the destination.")
            }
            // A staged archive takes another xipSize on the destination volume.
            let minimum = saturating(xipSize, times: willStage ? 3 : 2)
            if freeBytes < minimum {
                let need = Self.formatBytes(minimum)
                let have = Self.formatBytes(freeBytes)
                return .error("""
                Not enough free disk space to extract this Xcode.xip.
                  XIP size: \(Self.formatBytes(xipSize))
                  Free space: \(have)
                  Need at least: \(need)

                On WSL, copy the .xip onto the Linux filesystem (for example ~/xcode) \
                and free space on that volume — extracting onto /mnt/c is both slow and \
                can look like a hang at 72%.
                """)
            }
            let recommended = max(saturating(xipSize, times: 8), 8 * 1024 * 1024 * 1024)
            if freeBytes < recommended {
                return .warning("""
                Warning: only \(Self.formatBytes(freeBytes)) free; extracting Xcode may need \
                around \(Self.formatBytes(recommended)).
                """)
            }
            return .ok
        }

        /// A sparse archive can report a size that would trap on multiplication.
        private static func saturating(_ size: Int64, times factor: Int64) -> Int64 {
            let (product, overflowed) = size.multipliedReportingOverflow(by: factor)
            return overflowed ? .max : product
        }

        static func formatBytes(_ value: Int64) -> String {
            let gb = Double(value) / (1024 * 1024 * 1024)
            if gb >= 1 {
                return String(format: "%.1f GB", gb)
            }
            let mb = Double(value) / (1024 * 1024)
            return String(format: "%.0f MB", mb)
        }
    }

    struct PreparedInput {
        var path: String
        var stagedPath: String?

        func cleanup() {
            if let stagedPath {
                try? FileManager.default.removeItem(atPath: stagedPath)
            }
        }
    }

    static func shouldStage(
        source: HostFilesystem.Kind,
        destination: HostFilesystem.Kind
    ) -> Bool {
        source.isSlow && !destination.isSlow
    }

    static func appImageHint(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard environment["APPIMAGE"] != nil else { return nil }
        return """
        Note: xtool is running from an AppImage. If extraction appears stuck, rerun with \
        APPIMAGE_EXTRACT_AND_RUN=1 so the binary is not served through FUSE.
        """
    }

    static func stallMessage(
        progress: Progress,
        source: HostFilesystem.Kind,
        wasStaged: Bool = false,
        isAppImage: Bool
    ) -> String {
        var lines = [
            """
            XIP extraction made no progress for \(Int(stallTimeout.components.seconds / 60)) minutes \
            (\(progress.percent)% read, \(progress.filesWritten) files written).
            """,
        ]
        if wasStaged {
            lines.append("""
            The archive was already copied from the \(source.displayName) filesystem onto the \
            output disk, so its location is not the cause.
            """)
        } else if source.isSlow {
            lines.append("""
            The archive is on a \(source.displayName) filesystem. Copy it onto the Linux disk \
            (for example ~/xcode/Xcode.xip) instead of /mnt/c, then retry.
            """)
        }
        if isAppImage {
            lines.append("""
            xtool is running from an AppImage FUSE mount. Rerun with APPIMAGE_EXTRACT_AND_RUN=1.
            """)
        }
        if !source.isSlow && !isAppImage {
            lines.append("""
            This is common on WSL when the .xip lives on /mnt/c (9p/drvfs) or when AppImage FUSE \
            is serving the xtool binary. Copy the archive onto ext4 and rerun with \
            APPIMAGE_EXTRACT_AND_RUN=1.
            """)
        }
        return lines.joined(separator: "\n")
    }

    static func stageIfNeeded(
        inputPath: String,
        outDir: String,
        sourceKind: HostFilesystem.Kind? = nil,
        destinationKind: HostFilesystem.Kind? = nil,
        timeout: Duration = stallTimeout,
        pollInterval: Duration = .seconds(15),
        copy: @escaping @Sendable (String, String, @Sendable () -> Void) throws -> Void = copyReportingProgress
    ) async throws -> PreparedInput {
        let source = sourceKind ?? HostFilesystem.kind(of: inputPath)
        let destination = destinationKind ?? HostFilesystem.kind(of: outDir)
        guard shouldStage(source: source, destination: destination) else {
            return PreparedInput(path: inputPath, stagedPath: nil)
        }

        let stagedDir = URL(fileURLWithPath: outDir).appendingPathComponent(".xip-stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedDir, withIntermediateDirectories: true)
        let stagedPath = stagedDir.appendingPathComponent("Xcode.xip").path
        d.out.print("[Copying XIP] Source is on \(source.displayName); copying onto the Linux filesystem...", flush: true)
        let activity = CopyActivity()
        do {
            try await race {
                try await runBlocking { try copy(inputPath, stagedPath) { activity.note() } }
            } watchdog: {
                while !Task.isCancelled {
                    try await Task.sleep(for: pollInterval)
                    if activity.idle >= timeout {
                        throw Stall(message: copyStallMessage(source: source, timeout: timeout))
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(atPath: stagedPath)
            if let stall = error as? Stall {
                d.out.print()
                throw Console.Error(stall.message)
            }
            throw error
        }
        return PreparedInput(path: stagedPath, stagedPath: stagedPath)
    }

    static func copyStallMessage(source: HostFilesystem.Kind, timeout: Duration) -> String {
        """
        Copying the XIP off the \(source.displayName) filesystem made no progress for \
        \(Int(timeout.components.seconds / 60)) minutes. Copy it onto the Linux disk (for example \
        ~/xcode/Xcode.xip) yourself, then retry with that path.
        """
    }

    /// A read stuck on a slow mount would pin a cooperative thread, and on a
    /// small machine that could keep the watchdog from running.
    private static func runBlocking(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withEscapedDependencies { dependencies in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global().async {
                    dependencies.yield {
                        continuation.resume(with: Result { try work() })
                    }
                }
            }
        }
    }

    private static func copyReportingProgress(
        from source: String,
        to destination: String,
        onProgress: @Sendable () -> Void
    ) throws {
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: source))
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination, contents: nil) else {
            throw Console.Error("Could not create '\(destination)'")
        }
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: destination))
        defer { try? output.close() }

        let total = try input.seekToEnd()
        try input.seek(toOffset: 0)
        var copied: UInt64 = 0
        var reported: UInt64?
        while let chunk = try input.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
            copied += UInt64(chunk.count)
            onProgress()
            let percent = total > 0 ? copied * 100 / total : 100
            if percent != reported {
                reported = percent
                d.out.print("\r[Copying XIP] \(percent)%", terminator: "", flush: true)
            }
        }
        d.out.print()
    }

    static func checkFreeSpace(
        inputPath: String,
        outDir: String,
        sourceKind: HostFilesystem.Kind? = nil,
        destinationKind: HostFilesystem.Kind? = nil,
        measureFreeBytes: (String) -> Int64? = HostFilesystem.freeBytes(at:)
    ) throws {
        let source = sourceKind ?? HostFilesystem.kind(of: inputPath)
        let destination = destinationKind ?? HostFilesystem.kind(of: outDir)
        let attributes = try FileManager.default.attributesOfItem(atPath: inputPath)
        let xipSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        switch DiskSpace.evaluate(
            xipSize: xipSize,
            freeBytes: measureFreeBytes(outDir),
            willStage: shouldStage(source: source, destination: destination)
        ) {
        case .ok:
            break
        case .warning(let message):
            d.out.print(message)
        case .error(let message):
            throw Console.Error(message)
        }
    }

    struct Stall: Error {
        var message: String
    }

    /// Returns as soon as `work` finishes or `watchdog` throws. unxip ignores
    /// cancellation, so structured concurrency would hold a watchdog error until
    /// a stuck `work` returned. Here `work` is an unstructured task that is simply
    /// abandoned, and the caller is expected to fail the process.
    static func race<T: Sendable>(
        work: @escaping @Sendable () async throws -> T,
        watchdog: @escaping @Sendable () async throws -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let outcome = RaceOutcome(continuation)
            let watching = Task {
                do {
                    try await watchdog()
                } catch is CancellationError {
                    // `work` finished first.
                } catch {
                    outcome.finish(.failure(error))
                }
            }
            Task {
                do {
                    let value = try await work()
                    watching.cancel()
                    outcome.finish(.success(value))
                } catch {
                    watching.cancel()
                    outcome.finish(.failure(error))
                }
            }
        }
    }
}

private final class CopyActivity: @unchecked Sendable {
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private var last = ContinuousClock.now

    func note() {
        lock.lock()
        defer { lock.unlock() }
        last = clock.now
    }

    var idle: Duration {
        lock.lock()
        defer { lock.unlock() }
        return clock.now - last
    }
}

private final class RaceOutcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

actor XIPProgressTracker {
    private var progress: XIPExtraction.Progress
    private var lastPrinted = ""
    private let started: ContinuousClock.Instant
    private let clock = ContinuousClock()
    private let sourceKind: HostFilesystem.Kind
    private let wasStaged: Bool
    private let isAppImage: Bool

    init(totalBytes: Int64, sourceKind: HostFilesystem.Kind, wasStaged: Bool, isAppImage: Bool) {
        self.progress = XIPExtraction.Progress(
            bytesRead: 0,
            totalBytes: totalBytes,
            filesWritten: 0,
            lastChange: .zero
        )
        self.started = ContinuousClock.now
        self.sourceKind = sourceKind
        self.wasStaged = wasStaged
        self.isAppImage = isAppImage
    }

    func setBytesRead(_ bytesRead: Int64) {
        progress.bytesRead = bytesRead
        progress.lastChange = clock.now - started
        emit(force: false)
    }

    func noteFile() {
        progress.filesWritten += 1
        progress.lastChange = clock.now - started
        emit(force: false)
    }

    func noteFreeBytes(_ freeBytes: Int64) {
        if progress.noteFreeBytes(freeBytes, at: clock.now - started) {
            emit(force: true, suffix: " (still working)")
        }
    }

    func heartbeat() throws {
        let elapsed = clock.now - started
        if progress.isStalled(at: elapsed, timeout: XIPExtraction.stallTimeout) {
            throw XIPExtraction.Stall(
                message: XIPExtraction.stallMessage(
                    progress: progress,
                    source: sourceKind,
                    wasStaged: wasStaged,
                    isAppImage: isAppImage
                )
            )
        }
        if progress.isStalled(at: elapsed, timeout: XIPExtraction.stallWarning) {
            emit(force: true, suffix: " (still working)")
        }
    }

    private func emit(force: Bool, suffix: String = "") {
        let line = progress.statusLine + suffix
        guard force || line != lastPrinted else { return }
        lastPrinted = line
        d.out.print("\r\(line)", terminator: "", flush: true)
    }
}
