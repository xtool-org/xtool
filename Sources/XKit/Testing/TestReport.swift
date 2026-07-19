//
//  TestReport.swift
//  XKit
//
//  A single internal result model every reporter (console, JUnit, JSON, HTML) derives from, so
//  adding a reporter doesn't touch the execution path -- `TestCommand` builds one of these while
//  consuming `TestManagerdSession.events`, then hands it to whichever reporters were requested.

import Foundation

public struct TestCaseReport: Sendable, Codable, Equatable {
    public var testClass: String
    public var testMethod: String
    public var status: TestCaseStatus
    public var duration: Double
    public var failureMessages: [String]
    /// Set only for a `.failed` case, and only when `--screenshot-on-failure`-equivalent capture
    /// succeeded -- relative to the report directory, not an absolute path, so a report directory
    /// stays portable when copied off the machine that produced it.
    public var screenshotPath: String?

    public init(
        testClass: String,
        testMethod: String,
        status: TestCaseStatus,
        duration: Double,
        failureMessages: [String] = [],
        screenshotPath: String? = nil
    ) {
        self.testClass = testClass
        self.testMethod = testMethod
        self.status = status
        self.duration = duration
        self.failureMessages = failureMessages
        self.screenshotPath = screenshotPath
    }

    public var identifier: String { "\(testClass)/\(testMethod)" }
}

/// One full `xtool test` invocation against one device. With `--repeat`, each repetition produces
/// its own `TestRunReport`; with `--parallel`, one per device -- `TestReport` (below) aggregates
/// across both.
public struct TestRunReport: Sendable, Codable, Equatable {
    public var deviceName: String
    public var deviceUDID: String
    public var productVersion: String
    public var testBundleName: String
    public var startedAt: Date
    public var finishedAt: Date
    public var testCases: [TestCaseReport]
    /// Relative path (see `TestCaseReport.screenshotPath`) to a captured device syslog window
    /// covering this run, if log capture was requested and succeeded.
    public var syslogPath: String?
    /// Relative paths (see `TestCaseReport.screenshotPath`) to `.ips`/`.crash` files pulled from
    /// the device's crash log store that were written during this run, if crash log collection
    /// was requested -- empty (not necessarily an error) whenever nothing actually crashed.
    public var crashLogPaths: [String]
    /// Set if the run itself failed before any test cases could be collected (DDI mount failure,
    /// connection drop, etc.) -- distinct from a test case failing, which is `TestCaseReport`.
    public var infrastructureError: String?

    public init(
        deviceName: String,
        deviceUDID: String,
        productVersion: String,
        testBundleName: String,
        startedAt: Date,
        finishedAt: Date,
        testCases: [TestCaseReport],
        syslogPath: String? = nil,
        crashLogPaths: [String] = [],
        infrastructureError: String? = nil
    ) {
        self.deviceName = deviceName
        self.deviceUDID = deviceUDID
        self.productVersion = productVersion
        self.testBundleName = testBundleName
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.testCases = testCases
        self.syslogPath = syslogPath
        self.crashLogPaths = crashLogPaths
        self.infrastructureError = infrastructureError
    }

    public var passCount: Int { testCases.count { $0.status == .passed } }
    public var failCount: Int { testCases.count { $0.status == .failed } }
    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

/// The top-level result of an `xtool test` invocation, spanning every device x repetition
/// combination that ran.
public struct TestReport: Sendable, Codable, Equatable {
    public var runs: [TestRunReport]

    public init(runs: [TestRunReport]) {
        self.runs = runs
    }

    public var passCount: Int { runs.reduce(0) { $0 + $1.passCount } }
    public var failCount: Int { runs.reduce(0) { $0 + $1.failCount } }
    /// `true` if every run finished infra-cleanly (whether or not individual test cases failed)
    /// and at least one run happened at all.
    public var allRunsCompleted: Bool { !runs.isEmpty && runs.allSatisfy { $0.infrastructureError == nil } }
}
