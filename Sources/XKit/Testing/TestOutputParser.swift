//
//  TestOutputParser.swift
//  XKit
//
//  Parses the on-device XCTest runner's own human-readable console output (relayed to us via
//  `outputReceived:fromProcess:atTime:` on the instruments DTX connection) -- the same
//  "Test Case '-[Class method]' started/passed/failed (D seconds)." / "<file>:<line>: error:
//  -[Class method] : message" / "Test Suite 'X' passed/failed at ...\n\t Executed N tests, with M
//  failures (K unexpected) in ..." format `xcodebuild`/xcpretty parse -- since it's the one
//  reliable source of per-test-case names: the structured `_XCT_testCaseWithIdentifier:...`
//  callbacks carry an opaque numeric identifier in this protocol version, not a class/method name
//  (confirmed against real hardware, see `TestManagerdEvent.testCaseFinished`'s doc comment), and
//  (also confirmed against real hardware, this session) the structured callbacks can go missing
//  entirely for a run that otherwise completed successfully on-device. This text format is the
//  same one Xcode's own `xcodebuild` has relied on for CI consumption for over a decade, so
//  parsing it isn't a fragile workaround -- it's the de facto stable interface.

import Foundation

public enum TestCaseStatus: String, Sendable, Equatable, Codable {
    case passed
    case failed
}

public enum TestOutputEvent: Sendable, Equatable {
    case testCaseStarted(testClass: String, testMethod: String)
    case testCaseFinished(testClass: String, testMethod: String, status: TestCaseStatus, duration: Double)
    /// A `<file>:<line>: error: -[Class method] : message` line -- always immediately precedes the
    /// corresponding `.testCaseFinished(..., status: .failed, ...)` line, so callers should buffer
    /// these and attach them to the next finished event for the same class/method.
    case failureDetail(testClass: String, testMethod: String, file: String?, line: Int?, message: String)
    case suiteFinished(suiteName: String, runCount: Int, failureCount: Int)
}

public enum TestOutputParser {
    private static let startedRegex = try! NSRegularExpression(
        pattern: #"^Test Case '-\[(\S+) (\S+)\]' started\.$"#
    )
    private static let finishedRegex = try! NSRegularExpression(
        pattern: #"^Test Case '-\[(\S+) (\S+)\]' (passed|failed) \(([\d.]+) seconds\)\.$"#
    )
    private static let failureDetailRegex = try! NSRegularExpression(
        pattern: #"^(?:(.+?):(\d+): )?error: -\[(\S+) (\S+)\] : (.*)$"#
    )
    // The suite summary is two physical lines within one `outputReceived` chunk: the "Test Suite
    // '...' passed/failed at ..." header and a tab-indented "Executed N tests..." line -- matched
    // together (`.dotMatchesLineSeparators`) since they always arrive as a single unit.
    private static let suiteFinishedRegex = try! NSRegularExpression(
        pattern: #"Test Suite '([^']+)' (?:passed|failed) at [^\n]+\n\s*Executed (\d+) tests?, with (\d+) failures?"#,
        options: [.dotMatchesLineSeparators]
    )

    /// Parses every event found in `text`, which may contain one or more lines (an
    /// `outputReceived:fromProcess:atTime:` chunk is not guaranteed to be exactly one line).
    public static func parse(_ text: String) -> [TestOutputEvent] {
        var events: [TestOutputEvent] = []

        if let match = firstMatch(suiteFinishedRegex, in: text),
           let suiteName = group(match, 1, in: text),
           let runCount = group(match, 2, in: text).flatMap(Int.init),
           let failureCount = group(match, 3, in: text).flatMap(Int.init) {
            events.append(.suiteFinished(suiteName: suiteName, runCount: runCount, failureCount: failureCount))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            if let match = firstMatch(startedRegex, in: line),
               let testClass = group(match, 1, in: line),
               let testMethod = group(match, 2, in: line) {
                events.append(.testCaseStarted(testClass: testClass, testMethod: testMethod))
                continue
            }
            if let match = firstMatch(finishedRegex, in: line),
               let testClass = group(match, 1, in: line),
               let testMethod = group(match, 2, in: line),
               let statusString = group(match, 3, in: line),
               let status = TestCaseStatus(rawValue: statusString),
               let duration = group(match, 4, in: line).flatMap(Double.init) {
                events.append(.testCaseFinished(testClass: testClass, testMethod: testMethod, status: status, duration: duration))
                continue
            }
            if let match = firstMatch(failureDetailRegex, in: line),
               let testClass = group(match, 3, in: line),
               let testMethod = group(match, 4, in: line),
               let message = group(match, 5, in: line) {
                let file = group(match, 1, in: line)
                let lineNumber = group(match, 2, in: line).flatMap(Int.init)
                events.append(.failureDetail(testClass: testClass, testMethod: testMethod, file: file, line: lineNumber, message: message))
                continue
            }
        }

        return events
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}
