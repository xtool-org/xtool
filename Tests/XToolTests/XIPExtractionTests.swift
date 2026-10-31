import Dependencies
import Foundation
import Testing
import XUtils
@testable import XToolSupport

@Test func xipProgressLineIncludesFileCount() {
    var progress = XIPExtraction.Progress(
        bytesRead: 72,
        totalBytes: 100,
        filesWritten: 0,
        lastChange: .seconds(10)
    )
    #expect(progress.percent == 72)
    #expect(progress.statusLine == "[Extracting XIP] 72%")

    progress.filesWritten = 18421
    #expect(progress.statusLine == "[Extracting XIP] 72% (18421 files)")
}

@Test func xipProgressDetectsStall() {
    let progress = XIPExtraction.Progress(
        bytesRead: 72,
        totalBytes: 100,
        filesWritten: 12,
        lastChange: .seconds(10)
    )
    #expect(!progress.isStalled(at: .seconds(40), timeout: .seconds(45)))
    #expect(progress.isStalled(at: .seconds(55), timeout: .seconds(45)))
    #expect(progress.isStalled(at: .seconds(310), timeout: .seconds(300)))
}

@Test func xipStagingCopiesOffSlowFilesystemsOnly() {
    #expect(XIPExtraction.shouldStage(source: .network, destination: .native))
    #expect(XIPExtraction.shouldStage(source: .fuse, destination: .native))
    #expect(!XIPExtraction.shouldStage(source: .native, destination: .native))
    #expect(!XIPExtraction.shouldStage(source: .network, destination: .network))
    #expect(!XIPExtraction.shouldStage(source: .native, destination: .fuse))
}

@Test func xipStageIfNeededCopiesNinePSource() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("XIPStageTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let outDir = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("Xcode.xip")
    try Data("xar!".utf8).write(to: source)

    let staged = try await withDependencies {
        $0.out = CommandOutput { _, _, _ in }
    } operation: {
        try await XIPExtraction.stageIfNeeded(
            inputPath: source.path,
            outDir: outDir.path,
            sourceKind: .network,
            destinationKind: .native
        )
    }
    defer { staged.cleanup() }

    #expect(staged.stagedPath != nil)
    #expect(staged.path != source.path)
    #expect(FileManager.default.fileExists(atPath: staged.path))
    #expect(try String(contentsOfFile: staged.path, encoding: .utf8) == "xar!")
    staged.cleanup()
    #expect(!FileManager.default.fileExists(atPath: staged.path))
}

@Test func xipStageIfNeededLeavesNativeSourceInPlace() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("XIPStageNative-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let outDir = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("Xcode.xip")
    try Data("xar!".utf8).write(to: source)

    let prepared = try await XIPExtraction.stageIfNeeded(
        inputPath: source.path,
        outDir: outDir.path,
        sourceKind: .native,
        destinationKind: .native
    )
    #expect(prepared.stagedPath == nil)
    #expect(prepared.path == source.path)
}

private func stagingFixture(_ name: String) throws -> (root: URL, source: URL, outDir: URL, staged: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    let outDir = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("Xcode.xip")
    try Data("xar!".utf8).write(to: source)
    let staged = outDir.appendingPathComponent(".xip-stage/Xcode.xip")
    return (root, source, outDir, staged)
}

private struct CopyFailed: Error {}

@Test func xipStagingRemovesThePartialCopyWhenCopyingFails() async throws {
    let fixture = try stagingFixture("XIPStageFailure")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    await #expect(throws: CopyFailed.self) {
        try await withDependencies {
            $0.out = CommandOutput { _, _, _ in }
        } operation: {
            _ = try await XIPExtraction.stageIfNeeded(
                inputPath: fixture.source.path,
                outDir: fixture.outDir.path,
                sourceKind: .network,
                destinationKind: .native,
                copy: { _, destination, _ in
                    try Data("xa".utf8).write(to: URL(fileURLWithPath: destination))
                    throw CopyFailed()
                }
            )
        }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.staged.path))
}

@Test(.timeLimit(.minutes(1)))
func xipStagingReportsAStuckCopy() async throws {
    let fixture = try stagingFixture("XIPStageStall")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    // Stands in for a read blocked on a slow mount.
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }

    do {
        _ = try await withDependencies {
            $0.out = CommandOutput { _, _, _ in }
        } operation: {
            try await XIPExtraction.stageIfNeeded(
                inputPath: fixture.source.path,
                outDir: fixture.outDir.path,
                sourceKind: .network,
                destinationKind: .native,
                timeout: .milliseconds(50),
                pollInterval: .milliseconds(10),
                copy: { _, _, _ in release.wait() }
            )
        }
        Issue.record("expected the stuck copy to be reported")
    } catch {
        #expect("\(error)".contains("made no progress"))
        #expect("\(error)".contains("network/9p"))
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.staged.path))
}

@Test(.timeLimit(.minutes(1)))
func xipStagingStopsAnAbandonedCopyFromRecreatingTheArchive() async throws {
    let fixture = try stagingFixture("XIPStageAbandoned")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)

    await #expect(throws: (any Error).self) {
        try await withDependencies {
            $0.out = CommandOutput { _, _, _ in }
        } operation: {
            _ = try await XIPExtraction.stageIfNeeded(
                inputPath: fixture.source.path,
                outDir: fixture.outDir.path,
                sourceKind: .network,
                destinationKind: .native,
                timeout: .milliseconds(50),
                pollInterval: .milliseconds(10),
                copy: { source, destination, activity in
                    // Stands in for a blocked open of the source.
                    release.wait()
                    defer { finished.signal() }
                    try XIPExtraction.copyReportingProgress(
                        from: source,
                        to: destination,
                        activity: activity
                    )
                }
            )
        }
    }
    release.signal()
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            finished.wait()
            continuation.resume()
        }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.staged.path))
}

@Test(.timeLimit(.minutes(1)))
func xipStagingKeepsGoingWhileTheCopyMoves() async throws {
    let fixture = try stagingFixture("XIPStageMoving")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let prepared = try await withDependencies {
        $0.out = CommandOutput { _, _, _ in }
    } operation: {
        try await XIPExtraction.stageIfNeeded(
            inputPath: fixture.source.path,
            outDir: fixture.outDir.path,
            sourceKind: .network,
            destinationKind: .native,
            timeout: .seconds(1),
            pollInterval: .milliseconds(50),
            copy: { _, _, activity in
                for _ in 0..<15 {
                    try activity.note()
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        )
    }
    #expect(prepared.stagedPath == fixture.staged.path)
}

@Test func xipDiskSpaceErrorsWhenBelowTwiceTheArchive() {
    let result = XIPExtraction.DiskSpace.evaluate(
        xipSize: 2_000_000_000,
        freeBytes: 1_000_000_000
    )
    guard case .error(let message) = result else {
        Issue.record("expected a disk-space error")
        return
    }
    #expect(message.contains("Not enough free disk space"))
    #expect(message.contains("/mnt/c"))
}

@Test func xipDiskSpaceWarnsWhenBelowRecommended() {
    let result = XIPExtraction.DiskSpace.evaluate(
        xipSize: 2_000_000_000,
        freeBytes: 6_000_000_000
    )
    guard case .warning(let message) = result else {
        Issue.record("expected a disk-space warning")
        return
    }
    #expect(message.contains("Warning"))
}

@Test func xipAppImageHintIsOnlyForAppImageRuntime() {
    #expect(XIPExtraction.appImageHint(environment: [:]) == nil)
    let hint = XIPExtraction.appImageHint(environment: ["APPIMAGE": "/usr/local/bin/xtool"])
    #expect(hint?.contains("APPIMAGE_EXTRACT_AND_RUN=1") == true)
}

@Test func xipStallMessageMentionsWSLAndAppImage() {
    let progress = XIPExtraction.Progress(
        bytesRead: 72,
        totalBytes: 100,
        filesWritten: 18421,
        lastChange: .seconds(10)
    )
    let native = XIPExtraction.stallMessage(progress: progress, source: .native, isAppImage: false)
    #expect(native.contains("72%"))
    #expect(native.contains("18421 files"))
    #expect(native.contains("/mnt/c"))
    #expect(native.contains("APPIMAGE_EXTRACT_AND_RUN=1"))

    let nineP = XIPExtraction.stallMessage(progress: progress, source: .network, isAppImage: true)
    #expect(nineP.contains("network/9p"))
    #expect(nineP.contains("AppImage FUSE"))
}

@Test func xipDiskSpaceCountsTheStagedCopy() {
    let gb: Int64 = 1024 * 1024 * 1024
    if case .error = XIPExtraction.DiskSpace.evaluate(xipSize: 10 * gb, freeBytes: 25 * gb) {
        Issue.record("expected no error without staging")
    }
    guard case .error = XIPExtraction.DiskSpace.evaluate(xipSize: 10 * gb, freeBytes: 25 * gb, willStage: true) else {
        Issue.record("expected the staged copy to raise the minimum")
        return
    }
    guard case .warning = XIPExtraction.DiskSpace.evaluate(xipSize: 10 * gb, freeBytes: 31 * gb, willStage: true) else {
        Issue.record("expected a warning above the staged minimum")
        return
    }
}

@Test func xipRaceReportsAStallWithoutWaitingForStuckWork() async throws {
    let started = ContinuousClock.now
    await #expect(throws: XIPExtraction.Stall.self) {
        _ = try await XIPExtraction.race {
            // Stands in for unxip: it does not respond to cancellation.
            await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in }
        } watchdog: {
            throw XIPExtraction.Stall(message: "stalled")
        }
    }
    #expect(ContinuousClock.now - started < .seconds(5))
}

@Test(.timeLimit(.minutes(1)))
func xipRaceReturnsTheResultAndStopsTheWatchdog() async throws {
    let (watchdogExit, signal) = AsyncStream<Never>.makeStream()
    let value = try await XIPExtraction.race {
        42
    } watchdog: {
        defer { signal.finish() }
        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    #expect(value == 42)
    // Only ends when the watchdog has exited; the time limit catches a leak.
    for await _ in watchdogExit {}
}

@Test func xipStallMessageDoesNotBlameAStagedArchive() {
    let progress = XIPExtraction.Progress(
        bytesRead: 72,
        totalBytes: 100,
        filesWritten: 18421,
        lastChange: .seconds(10)
    )
    let message = XIPExtraction.stallMessage(
        progress: progress,
        source: .network,
        wasStaged: true,
        isAppImage: false
    )
    #expect(message.contains("already copied from the network/9p filesystem"))
    #expect(!message.contains("/mnt/c"))
    #expect(!message.contains("Copy it onto"))
}

@Test func xipDiskSpaceWarnsWhenFreeSpaceIsUnknown() {
    guard case .warning(let message) = XIPExtraction.DiskSpace.evaluate(xipSize: 1, freeBytes: nil) else {
        Issue.record("expected a warning")
        return
    }
    #expect(message.contains("could not measure"))
}

@Test func xipDiskSpaceHandlesOversizedArchives() {
    let gb: Int64 = 1024 * 1024 * 1024
    for willStage in [false, true] {
        guard case .error = XIPExtraction.DiskSpace.evaluate(
            xipSize: .max,
            freeBytes: 100 * gb,
            willStage: willStage
        ) else {
            Issue.record("expected an error for an oversized archive")
            return
        }
    }
    // Passes the minimum, so only the recommendation can overflow.
    let size = Int64.max / 4
    guard case .warning = XIPExtraction.DiskSpace.evaluate(xipSize: size, freeBytes: size * 3) else {
        Issue.record("expected a warning below the recommended space")
        return
    }
}

@Test func xipFreedSpaceDoesNotCountAsProgress() {
    var progress = XIPExtraction.Progress(
        bytesRead: 0,
        totalBytes: 100,
        filesWritten: 0,
        lastChange: .zero
    )
    let first = progress.noteFreeBytes(1000, at: .seconds(15))
    let freed = progress.noteFreeBytes(2000, at: .seconds(30))
    #expect(!first)
    #expect(!freed)
    #expect(progress.lastChange == .zero)

    let consumed = progress.noteFreeBytes(1900, at: .seconds(45))
    #expect(consumed)
    #expect(progress.lastChange == .seconds(45))
}

@Test func xipProgressShowsActivityWhenSpaceIsConsumed() async {
    let output = LockIsolated(Data())
    await withDependencies {
        $0.out = CommandOutput { data, _, _ in output.withValue { $0.append(data) } }
    } operation: {
        let tracker = XIPProgressTracker(
            totalBytes: 100,
            sourceKind: .native,
            wasStaged: false,
            isAppImage: false
        )
        await tracker.noteFreeBytes(1000)
        await tracker.noteFreeBytes(2000)
        #expect(output.value.isEmpty)
        await tracker.noteFreeBytes(1900)
    }
    #expect(String(decoding: output.value, as: UTF8.self).contains("(still working)"))
}

@Test func xipFreeSpaceChangesCountAsProgress() {
    var progress = XIPExtraction.Progress(
        bytesRead: 0,
        totalBytes: 100,
        filesWritten: 0,
        lastChange: .zero
    )
    progress.noteFreeBytes(1000, at: .seconds(15))
    progress.noteFreeBytes(1000, at: .seconds(30))
    #expect(progress.lastChange == .zero)

    progress.noteFreeBytes(900, at: .seconds(290))
    #expect(!progress.isStalled(at: .seconds(310), timeout: .seconds(300)))
    #expect(progress.isStalled(at: .seconds(590), timeout: .seconds(300)))
}

@Test func xipCheckFreeSpaceCountsTheStagedCopy() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("XIPFreeSpaceTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("Xcode.xip")
    try Data(repeating: 0, count: 100).write(to: source)

    func check(sourceKind: HostFilesystem.Kind) throws {
        try withDependencies {
            $0.out = CommandOutput { _, _, _ in }
        } operation: {
            try XIPExtraction.checkFreeSpace(
                inputPath: source.path,
                outDir: root.path,
                sourceKind: sourceKind,
                destinationKind: .native,
                measureFreeBytes: { _ in 250 }
            )
        }
    }

    try check(sourceKind: .native)
    #expect(throws: (any Error).self) {
        try check(sourceKind: .network)
    }
}
