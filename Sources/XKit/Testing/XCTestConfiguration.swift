//
//  XCTestConfiguration.swift
//  XKit
//
//  The plist Xcode writes into the Runner app's sandbox (as `<Runner>-<SESSION>.xctestconfiguration`)
//  to tell the on-device XCTest runner which bundle to load and how to report results. Field set
//  and defaults transcribed from appium-ios-device's `XCTestConfiguration` class in
//  `lib/instrument/transformer/nskeyed.js` (Apache-2.0 -- read for the required keys/defaults,
//  rewritten from scratch in Swift here).

import Foundation

public struct XCTestConfiguration: Sendable {
    /// `file://` URL to the `.xctest` bundle inside the Runner app, e.g.
    /// `file:///path/to/Runner.app/PlugIns/MyTests.xctest`.
    public var testBundleURL: String
    /// Uniquely identifies this test run; also used to name the `.xctestconfiguration` file.
    public var sessionIdentifier: UUID
    public var productModuleName: String
    /// Bundle ID of the app under test, for UI tests that drive a separate app. `nil` for tests
    /// hosted directly inside the Runner (plain XCTest unit/integration tests).
    public var targetApplicationBundleID: String?
    public var targetApplicationPath: String
    public var testsToRun: [String]?
    public var testsToSkip: [String]?
    public var reportResultsToIDE: Bool = true
    public var reportActivities: Bool = true
    public var testsDrivenByIDE: Bool = false
    public var initializeForUITesting: Bool = true
    /// `/Developer/Library/...` pre-17, `/System/Developer/Library/...` on 17+ -- confirmed
    /// against pymobiledevice3's `to_xctestconfiguration`, which switches on this same threshold.
    /// Left at the pre-17 default here; on real iOS 26 hardware (this session) leaving this at the
    /// pre-17 path didn't block the run outright, but the runner's post-test-case automation
    /// session re-acquisition failed with "No bundle at path /Developer/Library/PrivateFrameworks/
    /// XCTAutomationSupport.framework", which then stalled the session instead of completing
    /// cleanly -- callers on 17+ devices must override this.
    public var automationFrameworkPath = "/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework"

    public init(
        testBundleURL: String,
        sessionIdentifier: UUID,
        productModuleName: String,
        targetApplicationBundleID: String? = nil,
        targetApplicationPath: String = "/KEEP-THIS-NOT-EMPTY/KEEP-THIS-NOT-EMPTY",
        testsToRun: [String]? = nil,
        testsToSkip: [String]? = nil
    ) {
        self.testBundleURL = testBundleURL
        self.sessionIdentifier = sessionIdentifier
        self.productModuleName = productModuleName
        self.targetApplicationBundleID = targetApplicationBundleID
        self.targetApplicationPath = targetApplicationPath
        self.testsToRun = testsToRun
        self.testsToSkip = testsToSkip
    }

    /// Encodes to the NSKeyedArchiver-compatible `bplist00` xtool writes to the device.
    func archived() -> Data {
        NSKeyedArchive.archive(keyedValue)
    }

    /// The un-archived `NSKeyedValue` form, needed as-is (not re-archived) when this
    /// configuration must be sent as a DTX reply payload -- `DTXMessage.encoded()` already
    /// archives its `payload` itself, so nesting `archived()`'s bytes there would double-archive.
    /// See `TestManagerdSession`'s `_XCT_testRunnerReadyWithCapabilities:` handler.
    var keyedValue: NSKeyedValue {
        var properties: [(String, NSKeyedValue)] = [
            ("aggregateStatisticsBeforeCrash", .dictionary(["XCSuiteRecordsKey": .dictionary([:])])),
            ("automationFrameworkPath", .string(automationFrameworkPath)),
            ("disablePerformanceMetrics", .bool(false)),
            ("emitOSLogs", .bool(false)),
            ("formatVersion", .boxed(.int(2))),
            ("gatherLocalizableStringsData", .bool(false)),
            ("initializeForUITesting", .bool(initializeForUITesting)),
            ("productModuleName", .string(productModuleName)),
            ("randomExecutionOrderingSeed", .null),
            ("reportActivities", .bool(reportActivities)),
            ("reportResultsToIDE", .bool(reportResultsToIDE)),
            ("systemAttachmentLifetime", .int(2)),
            ("targetApplicationArguments", .array([])),
            ("targetApplicationBundleID", targetApplicationBundleID.map(NSKeyedValue.string) ?? .null),
            ("targetApplicationEnvironment", .null),
            ("targetApplicationPath", .string(targetApplicationPath)),
            ("testApplicationDependencies", .dictionary([:])),
            (
                "testBundleURL",
                .object(className: "NSURL", properties: [
                    ("NS.base", .null),
                    ("NS.relative", .string(testBundleURL)),
                ])
            ),
            ("testExecutionOrdering", .int(0)),
            ("testTimeoutsEnabled", .bool(false)),
            ("testsDrivenByIDE", .bool(testsDrivenByIDE)),
            ("testsMustRunOnMainThread", .bool(true)),
            // Legacy `NSSet<NSString>` form, kept for pre-17 runners.
            ("testsToRun", testsToRun.map { .set($0.map(NSKeyedValue.string)) } ?? .null),
            ("testsToSkip", testsToSkip.map { .set($0.map(NSKeyedValue.string)) } ?? .null),
            // iOS 17+ form -- confirmed against pymobiledevice3's `xctest_types.py` (read for the
            // wire shape only, not copied): "the legacy testsToRun/testsToSkip NSSet<NSString>
            // keys are ignored by modern runners" once `testIdentifiersToRun`/
            // `testIdentifiersToSkip` (`XCTTestIdentifierSet` objects) are present at all -- this
            // was the actual, previously-unnoticed reason `--only`/`--skip` never had any effect
            // on real iOS 17+ hardware (this session): the legacy fields were being sent, and even
            // once correctly NSSet-encoded (see `NSKeyedValue.set`'s doc comment), the runner never
            // looked at them.
            ("testIdentifiersToRun", testsToRun.map(Self.testIdentifierSet) ?? .null),
            ("testIdentifiersToSkip", testsToSkip.map(Self.testIdentifierSet) ?? .null),
            ("treatMissingBaselinesAsFailures", .bool(false)),
            ("userAttachmentLifetime", .int(1)),
            (
                "sessionIdentifier",
                .object(className: "NSUUID", properties: [
                    ("NS.uuidbytes", .data(sessionIdentifier.dtxUUIDBytes)),
                ])
            ),
        ]
        // stable order makes archived output deterministic/testable; wire format doesn't care
        properties.sort { $0.0 < $1.0 }

        return .object(className: "XCTestConfiguration", properties: properties)
    }

    /// Parses `xtool test`'s `--only`/`--skip`/`--test-target` identifier syntax ("TestClass",
    /// "TestClass/testMethod", or a bare module/target name) into an `XCTTestIdentifierSet`.
    /// `options` follows XCTest's own convention (confirmed against pymobiledevice3's
    /// `XCTTestIdentifier.from_string`): `3` for a single-component identifier (matches everything
    /// nested under it -- a whole module or a whole class), `2` for a two-component leaf
    /// (class + method).
    private static func testIdentifierSet(_ specs: [String]) -> NSKeyedValue {
        let identifiers: [NSKeyedValue] = specs.map { spec in
            let components = spec.split(separator: "/").map(String.init)
            let options = components.count <= 1 ? 3 : 2
            return .object(className: "XCTTestIdentifier", properties: [
                ("c", .array(components.map(NSKeyedValue.string))),
                ("o", .int(Int64(options))),
            ])
        }
        return .object(className: "XCTTestIdentifierSet", properties: [
            ("identifiers", .mutableArray(identifiers)),
        ])
    }
}

extension UUID {
    /// The raw 16-byte representation NSKeyedArchiver's `NSUUID` uses for `NS.uuidbytes`.
    var dtxUUIDBytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}
