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

@Test func xipStageIfNeededCopiesNinePSource() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("XIPStageTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let outDir = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("Xcode.xip")
    try Data("xar!".utf8).write(to: source)

    let staged = try withDependencies {
        $0.out = CommandOutput { _, _, _ in }
    } operation: {
        try XIPExtraction.stageIfNeeded(
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
}

@Test func xipStageIfNeededLeavesNativeSourceInPlace() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("XIPStageNative-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let outDir = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("Xcode.xip")
    try Data("xar!".utf8).write(to: source)

    let prepared = try XIPExtraction.stageIfNeeded(
        inputPath: source.path,
        outDir: outDir.path,
        sourceKind: .native,
        destinationKind: .native
    )
    #expect(prepared.stagedPath == nil)
    #expect(prepared.path == source.path)
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

@Test func xipRaceReturnsTheResultAndStopsTheWatchdog() async throws {
    let value = try await XIPExtraction.race {
        42
    } watchdog: {
        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    #expect(value == 42)
}
