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
    }

    enum DiskSpace: Equatable, Sendable {
        case ok
        case warning(String)
        case error(String)

        static func evaluate(xipSize: Int64, freeBytes: Int64?, willStage: Bool = false) -> Self {
            guard let freeBytes else { return .ok }
            // A staged archive takes another xipSize on the destination volume.
            let minimum = xipSize * (willStage ? 3 : 2)
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
            let recommended = max(xipSize * 8, 8 * 1024 * 1024 * 1024)
            if freeBytes < recommended {
                return .warning("""
                Warning: only \(Self.formatBytes(freeBytes)) free; extracting Xcode may need \
                around \(Self.formatBytes(recommended)).
                """)
            }
            return .ok
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
        isAppImage: Bool
    ) -> String {
        var lines = [
            """
            XIP extraction made no progress for \(Int(stallTimeout.components.seconds / 60)) minutes \
            (\(progress.percent)% read, \(progress.filesWritten) files written).
            """,
        ]
        if source.isSlow {
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
        destinationKind: HostFilesystem.Kind? = nil
    ) throws -> PreparedInput {
        let source = sourceKind ?? HostFilesystem.kind(of: inputPath)
        let destination = destinationKind ?? HostFilesystem.kind(of: outDir)
        guard shouldStage(source: source, destination: destination) else {
            return PreparedInput(path: inputPath, stagedPath: nil)
        }

        let stagedDir = URL(fileURLWithPath: outDir).appendingPathComponent(".xip-stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedDir, withIntermediateDirectories: true)
        let stagedPath = stagedDir.appendingPathComponent("Xcode.xip").path
        d.out.print("[Copying XIP] Source is on \(source.displayName); copying onto the Linux filesystem...", flush: true)
        try FileManager.default.copyItem(atPath: inputPath, toPath: stagedPath)
        d.out.print("[Copying XIP] 100%")
        return PreparedInput(path: stagedPath, stagedPath: stagedPath)
    }

    static func checkFreeSpace(
        inputPath: String,
        outDir: String,
        sourceKind: HostFilesystem.Kind? = nil,
        destinationKind: HostFilesystem.Kind? = nil
    ) throws {
        let source = sourceKind ?? HostFilesystem.kind(of: inputPath)
        let destination = destinationKind ?? HostFilesystem.kind(of: outDir)
        let attributes = try FileManager.default.attributesOfItem(atPath: inputPath)
        let xipSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        switch DiskSpace.evaluate(
            xipSize: xipSize,
            freeBytes: HostFilesystem.freeBytes(at: outDir),
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
    private let isAppImage: Bool

    init(totalBytes: Int64, sourceKind: HostFilesystem.Kind, isAppImage: Bool) {
        self.progress = XIPExtraction.Progress(
            bytesRead: 0,
            totalBytes: totalBytes,
            filesWritten: 0,
            lastChange: .zero
        )
        self.started = ContinuousClock.now
        self.sourceKind = sourceKind
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

    func heartbeat() throws {
        let elapsed = clock.now - started
        if progress.isStalled(at: elapsed, timeout: XIPExtraction.stallTimeout) {
            throw XIPExtraction.Stall(
                message: XIPExtraction.stallMessage(
                    progress: progress,
                    source: sourceKind,
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
