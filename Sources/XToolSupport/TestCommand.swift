import Foundation
import XKit
import SwiftyMobileDevice
import ArgumentParser
import PackLib

struct TestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Build and run XCTest/XCUITest targets on a device",
        discussion: """
        Builds every XCTest target in the current SwiftPM package into a single combined test \
        bundle (matching `swift test`'s own model -- SwiftPM does not support per-target test \
        products), packages it into a Runner.app, installs it, and drives it via the same \
        testmanagerd protocol Xcode uses.

        For XCUITest runs that drive a separate app under test, install that app first (e.g. via \
        `xtool install`) and pass its bundle ID with --target-bundle-id.
        """
    )

    @OptionGroup var connectionOptions: ConnectionOptions

    @Option(
        help: ArgumentHelp(
            "Bundle ID of a separately-installed app to drive (for XCUITest)",
            discussion: "Leave unset for XCTest targets hosted directly inside the runner."
        )
    ) var targetBundleID: String?

    @Option(
        name: .customLong("test-target"),
        help: ArgumentHelp(
            "Which SwiftPM test target to run (e.g. MyAppUITests).",
            discussion: """
            If the package has more than one `.testTarget` and this isn't set, you'll be \
            prompted to choose one interactively. Only one test target actually runs per \
            invocation -- unlike `swift test`, which always builds every test target into one \
            combined bundle, `xtool test` still builds that combined bundle (SwiftPM leaves no \
            alternative) but only *executes* the chosen target's tests, since a UI test target \
            and a plain unit test target typically need different session settings (notably \
            --target-bundle-id) and shouldn't run mixed together in one session anyway.
            """
        )
    ) var testTarget: String?

    @Option(
        name: .customLong("only"),
        help: "Only run the given test identifier (TestClass or TestClass/testMethod). Repeatable."
    ) var testsToRun: [String] = []

    @Option(
        name: .customLong("skip"),
        help: "Skip the given test identifier (TestClass or TestClass/testMethod). Repeatable."
    ) var testsToSkip: [String] = []

    @Option(
        help: ArgumentHelp(
            "Custom target triple to build for",
            discussion: "Defaults to '\(PackOperation.defaultTriple)'"
        )
    ) var triple: String?

    @Option(name: .customLong("repeat"), help: "Run the whole test session this many times sequentially, aggregating results.")
    var repeatCount: Int = 1

    @Option(help: "Write a JUnit XML report to this path.")
    var junit: String?

    @Option(help: "Write a JSON report to this path.")
    var json: String?

    @Option(help: "Write an HTML report to this path.")
    var html: String?

    @Flag(help: "Capture a screenshot of the device on every failed test case.")
    var screenshotOnFailure = false

    @Flag(help: "Capture the device syslog for the duration of each run.")
    var captureSyslog = false

    @Flag(help: "Collect any on-device crash logs written during each run.")
    var captureCrashLogs = false

    @Option(help: ArgumentHelp(
        "Directory to write failure artifacts (screenshots, logs) into.",
        discussion: "Defaults to a timestamped directory under the current directory."
    ))
    var reportDirectory: String?

    @Flag(help: ArgumentHelp(
        "Run on every currently-connected device concurrently instead of just one.",
        discussion: "One run per device (no in-app parallelism), matching xcodebuild's own model."
    ))
    var parallel = false

    @Option(help: ArgumentHelp(
        "Fail a run if no event arrives from the device for this many seconds.",
        discussion: """
        Guards against a stalled (but still connected) session hanging forever -- a clean \
        disconnect is already detected and reported as an infrastructure error on its own, but a \
        session that stops producing events without the connection actually dropping previously \
        had no way to give up. Measured as an idle gap between events, not a cap on the whole \
        run, so a large --test-target sweep isn't penalized for legitimately taking a while.
        """
    ))
    var sessionTimeout: Int = 120

    @OptionGroup var buildOptions: PackOperation.BuildOptions

    func run() async throws {
        let token = try AuthToken.saved()

        print("Planning...")
        let schema: PackSchema
        let configPath = URL(fileURLWithPath: "xtool.yml")
        if FileManager.default.fileExists(atPath: configPath.path) {
            schema = try await PackSchema(url: configPath)
        } else {
            schema = .default
        }

        let buildSettings = try await BuildSettings(
            configuration: buildOptions.configuration,
            triple: triple ?? PackOperation.defaultTriple
        )
        let planner = Planner(buildSettings: buildSettings, schema: schema)
        let plan = try await planner.createPlan()

        guard let xcTest = plan.xcTest else {
            throw Console.Error("""
            No XCTest targets were found in this package. Add a `.testTarget` to Package.swift \
            (or an existing one has been excluded by SwiftPM) before running `xtool test`.
            """)
        }

        let (effectiveTestsToRun, chosenTarget) = try await resolveTestsToRun(xcTest: xcTest)

        // XCUITest drives a separate app under test, identified by --target-bundle-id -- without
        // it, testmanagerd has no idea what to launch, and `XCUIApplication()` (called with no
        // explicit bundle ID, the common case) ends up doing nothing useful. Xcode itself defaults
        // a UI test target to the app in the same project, so when the user didn't pass
        // --target-bundle-id and picked a target that looks like a UI test target (by the same
        // "UITests" naming convention Xcode's own project templates use), fall back to this
        // package's own app -- resolved per-device in `runOnDevice` (via `resolveInstalledBundleID`)
        // since `plan.app.bundleID` is only the raw, unprefixed value from `xtool.yml`/
        // `Package.swift`, not what's actually installed on a device signed with a free account.
        let autoDetectAppBundleID: String?
        if targetBundleID == nil, let chosenTarget, chosenTarget.hasSuffix("UITests") {
            autoDetectAppBundleID = plan.app.bundleID
        } else {
            autoDetectAppBundleID = nil
        }

        guard let sdk = try await DarwinSDK.current() else {
            throw Console.Error("No Darwin SDK installed. Run `xtool sdk install` first.")
        }
        let platformDeveloperDirectory = sdk.bundle.appendingPathComponent(
            "Developer/Platforms/iPhoneOS.platform/Developer", isDirectory: true
        )

        print("Building \(xcTest.testProductName)...")
        let packer = Packer(buildSettings: buildSettings, plan: plan)
        try await packer.buildOnly()
        guard let runnerURL = try await packer.packXCTestRunner(
            platformDeveloperDirectory: platformDeveloperDirectory
        ) else {
            throw Console.Error("Internal error: expected a Runner.app to be produced")
        }

        let wantsArtifacts = screenshotOnFailure || captureSyslog || captureCrashLogs
        let reportDir: URL? = (wantsArtifacts || junit != nil || json != nil || html != nil)
            ? try prepareReportDirectory()
            : nil

        let clients: [ClientDevice]
        if parallel {
            print("Waiting for devices to be connected...")
            clients = try await firstNonEmptyBatch(searchMode: connectionOptions.search)
            print("Running on \(clients.count) device(s): \(clients.map(\.deviceName).joined(separator: ", "))")
        } else {
            clients = [try await connectionOptions.client()]
        }

        let runReports: [TestRunReport]
        if clients.count > 1 {
            runReports = try await withThrowingTaskGroup(of: [TestRunReport].self) { group in
                for client in clients {
                    group.addTask {
                        try await self.runOnDevice(
                            client: client,
                            runnerURL: runnerURL,
                            xcTest: xcTest,
                            token: token,
                            reportDir: reportDir,
                            testsToRun: effectiveTestsToRun,
                            autoDetectAppBundleID: autoDetectAppBundleID
                        )
                    }
                }
                return try await group.reduce(into: []) { $0.append(contentsOf: $1) }
            }
        } else {
            runReports = try await runOnDevice(
                client: clients[0],
                runnerURL: runnerURL,
                xcTest: xcTest,
                token: token,
                reportDir: reportDir,
                testsToRun: effectiveTestsToRun,
                autoDetectAppBundleID: autoDetectAppBundleID
            )
        }

        let report = TestReport(runs: runReports)

        if let junit {
            let url = URL(fileURLWithPath: junit)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JUnitReporter.write(report, to: url)
            print("Wrote JUnit report to \(junit)")
        }
        if let json {
            let url = URL(fileURLWithPath: json)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONReporter.write(report, to: url)
            print("Wrote JSON report to \(json)")
        }
        if let html {
            let url = URL(fileURLWithPath: html)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try HTMLReporter.write(report, to: url)
            print("Wrote HTML report to \(html)")
        }

        let runDescription = [
            repeatCount > 1 ? "\(repeatCount) repeats" : nil,
            clients.count > 1 ? "\(clients.count) devices" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
        print("\n\(report.passCount) passed, \(report.failCount) failed" + (runDescription.isEmpty ? "" : " (\(runDescription))"))

        guard report.allRunsCompleted else {
            throw Console.Error("One or more runs did not complete (see above).")
        }
        if report.failCount > 0 {
            throw ExitCode.failure
        }
    }

    /// Resolves which test identifiers to actually run: explicit `--only` wins outright (the
    /// caller presumably already knows exactly what they want, so no target name is resolved in
    /// that case); otherwise, if the package has more than one `.testTarget`, prompts for one (or
    /// takes `--test-target` directly) and scopes the whole run to it via Apple's own
    /// `ModuleName`-as-identifier convention. A single-test-target package never prompts --
    /// `Console.choose` already special-cases exactly one element. The chosen target's name is
    /// also returned so the caller can default `--target-bundle-id` for a UI test target.
    private func resolveTestsToRun(xcTest: Plan.XCTestPlan) async throws -> (testsToRun: [String], chosenTarget: String?) {
        guard testsToRun.isEmpty else { return (testsToRun, nil) }

        let chosen: String
        if let testTarget {
            guard xcTest.testTargetNames.contains(testTarget) else {
                throw Console.Error("""
                No test target named '\(testTarget)' in this package. Available: \
                \(xcTest.testTargetNames.joined(separator: ", "))
                """)
            }
            chosen = testTarget
        } else {
            chosen = try await Console.choose(
                from: xcTest.testTargetNames,
                onNoElement: { throw Console.Error("No XCTest targets were found in this package.") },
                multiPrompt: "Multiple test targets found -- choose one to run (or pass --test-target):",
                formatter: { $0 }
            )
        }

        guard let path = xcTest.testTargetPaths[chosen] else { return ([chosen], chosen) }
        let classes = Self.xcTestCaseClassNames(inDirectory: URL(fileURLWithPath: path))
        guard !classes.isEmpty else {
            throw Console.Error("No XCTestCase subclasses found under '\(path)' for test target '\(chosen)'.")
        }
        return (classes, chosen)
    }

    /// Scans every `.swift` file under `directory` for `class Foo: XCTestCase` / `final class
    /// Foo: XCTestCase` declarations -- see `Plan.XCTestPlan.testTargetPaths`'s doc comment for
    /// why a bare module name can't be used as the `testsToRun` filter directly. A simple text
    /// scan, not full parsing: good enough for XCTest's own convention (one class per top-level
    /// declaration line), and avoids needing a second, separately-configured build just to
    /// enumerate tests (`swift test list` builds for the *host* triple, which fails outright for
    /// an iOS-only package like a UIKit/SwiftUI app -- confirmed against real hardware, this
    /// session).
    /// `applicationVerificationFailed` covers several unrelated provisioning failures too, but the
    /// free-tier-account app-count cap has a distinctive `details` message and was hit repeatedly
    /// against real hardware (this project's own history) with no actionable next step surfaced --
    /// just a raw `StatusError` dump naming the already-installed bundle IDs without saying what to
    /// do about them.
    private static func describeInstallFailure(_ error: InstallationProxyClient.StatusError) -> String {
        guard let details = error.details, let message = Self.installCapacityMessage(fromDetails: details) else {
            return "Failed to install the test runner: \(error)"
        }
        return message
    }

    /// Parses the already-installed bundle IDs back out of the device's raw `details` message and
    /// suggests `xtool uninstall` on one. Returns `nil` if `details` isn't this specific error.
    static func installCapacityMessage(fromDetails details: String) -> String? {
        guard details.contains("maximum number of installed apps") else { return nil }

        let quotedStringPattern = try! NSRegularExpression(pattern: #""([^"]+)""#)
        let ns = details as NSString
        let installedIDs = quotedStringPattern.matches(in: details, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }

        // Installed bundle IDs are reported team-ID-prefixed (e.g. "ABCDE12345.XTL-...actual-id"),
        // but `xtool uninstall` expects just the identifier after that prefix.
        let suggestion = installedIDs.first.map { id -> String in
            let strippedID = id.split(separator: ".", maxSplits: 1).count > 1
                ? String(id.split(separator: ".", maxSplits: 1)[1])
                : id
            return "\n\nFree up a slot first, e.g.: xtool uninstall \(strippedID)"
        } ?? ""

        return """
        This device has reached the maximum number of apps a free Apple Developer account can \
        have installed at once\(installedIDs.isEmpty ? "" : " (\(installedIDs.joined(separator: ", ")))").\
        \(suggestion)
        """
    }

    /// Scans every `.swift` file under `directory` for `XCTestCase` subclasses, resolving
    /// indirect inheritance (e.g. a shared `class BaseUITestCase: XCTestCase` with concrete
    /// `class FooUITests: BaseUITestCase` subclasses that hold the actual `test...` methods --
    /// confirmed against real hardware (this session) as a case a plain "inherits from
    /// XCTestCase directly" regex misses entirely: filtering on the base class name alone
    /// resolves to zero test methods, since XCTest addresses tests by their concrete class, not
    /// an ancestor's). Only classes that declare at least one `test...` method of their own are
    /// returned -- an abstract base with no directly-declared tests would otherwise waste a
    /// whole filter/session round-trip for zero results.
    static func xcTestCaseClassNames(inDirectory directory: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let classPattern = try! NSRegularExpression(pattern: #"\bclass\s+(\w+)\s*:\s*([^{]+?)\{"#)
        let testMethodPattern = try! NSRegularExpression(pattern: #"\bfunc\s+test\w*\s*\("#)

        var superclassByName: [String: String] = [:]
        var hasOwnTestMethod: Set<String> = []

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let ns = contents as NSString
            for match in classPattern.matches(in: contents, range: NSRange(location: 0, length: ns.length)) {
                guard let nameRange = Range(match.range(at: 1), in: contents),
                      let superListRange = Range(match.range(at: 2), in: contents)
                else { continue }
                let className = String(contents[nameRange])
                // Swift requires the superclass (if any) to be listed before any protocols, so
                // the first entry is either the real superclass or a protocol -- either way it's
                // the only entry worth treating as a potential superclass link.
                guard let firstSuper = String(contents[superListRange])
                    .split(separator: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !firstSuper.isEmpty
                else { continue }
                superclassByName[className] = firstSuper

                // Scope the test-method search to this class's own body via brace matching --
                // otherwise a `func test...` in a later sibling class would be misattributed here.
                var depth = 1
                var index = match.range.location + match.range.length
                while depth > 0, index < ns.length {
                    switch ns.character(at: index) {
                    case UInt16(UnicodeScalar("{").value): depth += 1
                    case UInt16(UnicodeScalar("}").value): depth -= 1
                    default: break
                    }
                    index += 1
                }
                let bodyStart = match.range.location + match.range.length
                let body = ns.substring(with: NSRange(location: bodyStart, length: max(0, index - 1 - bodyStart)))
                if testMethodPattern.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) != nil {
                    hasOwnTestMethod.insert(className)
                }
            }
        }

        func isXCTestCaseDescendant(_ name: String) -> Bool {
            var current = name
            var visited: Set<String> = []
            while let next = superclassByName[current], visited.insert(current).inserted {
                if next == "XCTestCase" { return true }
                current = next
            }
            return false
        }

        return superclassByName.keys
            .filter { hasOwnTestMethod.contains($0) && isXCTestCaseDescendant($0) }
            .sorted()
    }

    private func firstNonEmptyBatch(searchMode: ClientDevice.SearchMode) async throws -> [ClientDevice] {
        let stream = try await ClientDevice.search(mode: searchMode)
        for await devices in stream where !devices.isEmpty {
            return devices
        }
        throw CancellationError()
    }

    /// Installs the already-built runner, mounts the DDI, and runs the whole `--repeat` loop
    /// against one device -- extracted so `--parallel` can call this once per connected device
    /// concurrently via a `TaskGroup`, and the single-device path (the common case) can call it
    /// directly with one client.
    private func runOnDevice(
        client: ClientDevice,
        runnerURL: URL,
        xcTest: Plan.XCTestPlan,
        token: AuthToken,
        reportDir: URL?,
        testsToRun: [String],
        autoDetectAppBundleID: String?
    ) async throws -> [TestRunReport] {
        print("Installing \(xcTest.runnerProduct) to device: \(client.deviceName) (udid: \(client.udid))")

        let installDelegate = XToolInstallerDelegate()
        let installer = IntegratedInstaller(auth: token.authData(), delegate: installDelegate)
        let runnerBundleID: String
        do {
            runnerBundleID = try await installer.install(
                app: runnerURL,
                udid: client.udid,
                lookupMode: .only(client.connectionType),
                configureDevice: false
            )
            print("\nInstalled \(runnerBundleID)")
        } catch let error as CancellationError {
            throw error
        } catch let error as InstallationProxyClient.StatusError where error.type == .applicationVerificationFailed {
            throw Console.Error(Self.describeInstallFailure(error))
        } catch {
            throw Console.Error("Failed to install the test runner: \(error)")
        }

        // `targetBundleID` (the --target-bundle-id CLI option) wins outright; otherwise, if the
        // chosen test target looked like a UI test target, look up what this package's own app is
        // actually installed as on *this* device -- `autoDetectAppBundleID` is only the raw,
        // unprefixed value from `xtool.yml`/`Package.swift`, not the team-ID-prefixed form a
        // free-tier account's signing actually installs it under.
        let targetBundleID: String?
        if let explicit = self.targetBundleID {
            targetBundleID = explicit
        } else if let autoDetectAppBundleID {
            let installProxy = try InstallationProxyClient(device: client.device, label: "xtool-test")
            if let resolved = try TestManagerdSession.resolveInstalledBundleID(
                matching: autoDetectAppBundleID,
                client: installProxy
            ) {
                print("No --target-bundle-id given; defaulting to this package's own app (\(resolved)), since the chosen test target looks like a UI test target.")
                targetBundleID = resolved
            } else {
                throw Console.Error("""
                Could not find '\(autoDetectAppBundleID)' installed on \(client.deviceName) to drive as \
                the UI test target. Install it first (e.g. `xtool install`/`xtool dev`), or pass \
                --target-bundle-id explicitly if it's under a different bundle ID.
                """)
            }
        } else {
            targetBundleID = nil
        }

        let connection = try await Connection.connection(
            forUDID: client.udid,
            preferences: .init(lookupMode: .only(client.connectionType))
        ) { _ in }
        let productVersion = try await connection.client.value(
            ofType: String.self, forDomain: nil, key: "ProductVersion"
        )

        // testmanagerd/instruments are developer-only services exposed only once a Developer
        // Disk Image is mounted -- without this, `xtool test` only worked so far as some *other*
        // tool had already mounted one this boot (confirmed during this session: real-device
        // testing relied on pymobiledevice3, used for diagnostics, having done exactly that).
        do {
            print("Ensuring Developer Disk Image is mounted...")
            try await AutoDDIMounter.ensureMounted(connection: connection, productVersion: productVersion) { progress in
                print("\r[Mounting DDI] \(Int(progress * 100))%", terminator: "")
                fflush(stdoutSafe)
            }
            print()
        } catch {
            throw Console.Error("Failed to mount the Developer Disk Image: \(error)")
        }

        // iOS 17.4+ doesn't expose testmanagerd/instruments over classic lockdown at all -- try
        // the CoreDeviceProxy tunnel first and fall back to classic on `serviceUnavailable`
        // (the device itself is the source of truth here, not a version-string parse) rather than
        // requiring the caller to know which path applies.
        //
        // Re-opened fresh on *every* `--repeat` iteration below, not just once before the loop --
        // confirmed against real hardware (this session): reusing one tunnel across multiple
        // sequential `TestManagerdSession`s made every run after the first fail immediately with
        // `ioFailed(errno: 104)` (ECONNRESET). Something about a session's `stop()` (which closes
        // its three DTX connections and kills the runner process) leaves the underlying tunnel
        // socket unusable for opening new connections afterward, even though the tunnel object
        // itself doesn't report being closed -- not fully root-caused, but a fresh tunnel per
        // iteration reliably avoids it, matching the low relative cost of the RSD handshake.
        func openTunnel() throws -> (CoreDeviceProxyTunnel?, TestManagerdSession.TunnelContext?) {
            do {
                let t = try CoreDeviceProxyTunnel.connect(connection: connection)
                let socket = try PosixTCPSocket(address: t.address, port: t.rsdPort)
                let xpc = try RemoteXPCConnection(stream: socket)
                let handshake = try RSDHandshake.perform(over: xpc)
                return (t, .init(tunnel: t, rsd: handshake))
            } catch CDTunnelError.serviceUnavailable {
                return (nil, nil) // pre-17.4 device -- classic lockdown path.
            }
        }

        var runReports: [TestRunReport] = []
        for iteration in 1...max(1, repeatCount) {
            if repeatCount > 1 {
                print("\n=== \(client.deviceName): run \(iteration)/\(repeatCount) ===")
            }
            let startedAt = Date()

            var syslogCapture: SyslogCapture?
            if captureSyslog {
                syslogCapture = try? await SyslogCapture(connection: connection)
            }

            print("\nRunning \(xcTest.testProductName) on \(client.deviceName)...")
            // One session per filter entry, not one session filtered to all of them -- confirmed
            // against real hardware (this session): a single `XCTTestIdentifierSet` containing
            // more than one class-level (whole-class) identifier reliably runs only *one* of
            // them, and empirically not "first" or "last" but something else entirely (tested
            // multiple orderings/pairings) -- a genuine on-device XCTest limitation, not an
            // encoding bug (single-identifier filtering, including a class with 41 test methods,
            // is completely reliable). This mainly matters for `--test-target`, which expands a
            // chosen target into every `XCTestCase` class under it (`resolveTestsToRun`) -- a
            // real target routinely has more than one.
            let filters: [String?] = testsToRun.isEmpty ? [nil] : testsToRun
            var combinedTestCases: [TestCaseReport] = []
            var anyTimedOut = false
            var startFailure: Swift.Error?
            for filter in filters {
                // Fresh tunnel per session, not shared across the whole loop -- same reasoning
                // as `--repeat`'s own fix (see `openTunnel`'s doc comment): a tunnel that already
                // had a `TestManagerdSession` opened and stopped on it fails every subsequent
                // session with `ioFailed(errno: 104)`, confirmed against real hardware (this
                // session) once this per-filter loop started opening more than one session per
                // tunnel.
                let (tunnel, tunnelContext) = try openTunnel()
                defer { tunnel?.close() }
                if filter == filters.first, tunnel != nil {
                    print("Using iOS 17+ RSD tunnel for testmanagerd/instruments.")
                }
                let session = TestManagerdSession(connection: connection, productVersion: productVersion, tunnel: tunnelContext)
                do {
                    _ = try await session.start(
                        runnerBundleID: runnerBundleID,
                        testBundleName: xcTest.testProductName,
                        targetApplicationBundleID: targetBundleID,
                        testsToRun: filter.map { [$0] },
                        testsToSkip: testsToSkip.isEmpty ? nil : testsToSkip
                    )
                } catch {
                    await session.stop()
                    startFailure = error
                    break
                }

                do {
                    let outcome = try await consume(session: session, connection: connection, reportDir: reportDir)
                    combinedTestCases.append(contentsOf: outcome.testCases)
                    if outcome.timedOutWithoutResult { anyTimedOut = true }
                } catch {
                    // Ctrl-C (or any other cancellation) lands here -- without this, the runner
                    // process this session launched is left running on the device after every
                    // `xtool test` invocation, forcing a manual force-quit before the next run.
                    await session.stop()
                    await syslogCapture?.stop()
                    throw error
                }
                await session.stop()
            }

            if let startFailure {
                await syslogCapture?.stop()
                if repeatCount > 1 || parallel {
                    runReports.append(TestRunReport(
                        deviceName: client.deviceName,
                        deviceUDID: client.udid,
                        productVersion: productVersion,
                        testBundleName: xcTest.testProductName,
                        startedAt: startedAt,
                        finishedAt: Date(),
                        testCases: combinedTestCases,
                        infrastructureError: "\(startFailure)"
                    ))
                    continue
                }
                throw Console.Error("Failed to start the test session: \(startFailure)")
            }
            let outcome = RunOutcome(testCases: combinedTestCases, timedOutWithoutResult: anyTimedOut)

            let syslogPath = await syslogCapture?.stop(into: reportDir, runLabel: "\(client.udid)-run\(iteration)")

            var crashLogPaths: [String] = []
            if captureCrashLogs, let reportDir {
                crashLogPaths = collectCrashLogs(
                    connection: connection,
                    reportDir: reportDir,
                    runLabel: "\(client.udid)-run\(iteration)",
                    since: startedAt,
                    processNames: [xcTest.runnerProduct, targetBundleID?.components(separatedBy: ".").last].compactMap { $0 }
                )
            }

            runReports.append(TestRunReport(
                deviceName: client.deviceName,
                deviceUDID: client.udid,
                productVersion: productVersion,
                testBundleName: xcTest.testProductName,
                startedAt: startedAt,
                finishedAt: Date(),
                testCases: outcome.testCases,
                syslogPath: syslogPath,
                crashLogPaths: crashLogPaths,
                infrastructureError: outcome.timedOutWithoutResult
                    ? "Connection to the device was lost before the test run finished."
                    : nil
            ))
        }
        return runReports
    }

    private func prepareReportDirectory() throws -> URL {
        let dir: URL
        if let reportDirectory {
            dir = URL(fileURLWithPath: reportDirectory)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            dir = URL(fileURLWithPath: "xtool-test-report-\(formatter.string(from: Date()))")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct RunOutcome {
        var testCases: [TestCaseReport]
        /// The event stream ended (connection dropped) before a `.testSuiteFinished` event
        /// arrived -- distinct from a clean run where every test case is simply accounted for.
        var timedOutWithoutResult: Bool
    }

    /// Tracks how long it's been since the last event from `session.events`, polled by
    /// `consume`'s watchdog task -- an `actor` (rather than a plain mutable var) since it's
    /// written from the event-consuming task and read from the watchdog task concurrently.
    private actor IdleWatchdog {
        private var lastEventAt = Date()
        func poke() { lastEventAt = Date() }
        func secondsSinceLastEvent() -> TimeInterval { Date().timeIntervalSince(lastEventAt) }
    }

    /// Races the event-consuming loop (which returns once a `.testSuiteFinished` event arrives)
    /// against two things that exist purely to make this cancellable/boundable -- a bare `for
    /// await` over `session.events` (a plain `AsyncStream`) does not itself respond to `Task`
    /// cancellation or the passage of time:
    /// 1. A plain `Task.sleep` so Ctrl-C unwinds to the caller (where `session.stop()`, and the
    ///    app-kill it performs, actually runs) instead of hanging.
    /// 2. An idle watchdog (`sessionTimeout`) that fails the run if no event arrives for that long
    ///    -- a session that goes silent without the underlying connection actually dropping
    ///    previously had no way to give up short of the caller hitting Ctrl-C themselves. Idle
    ///    *gap*, not a cap on the whole run, so a long `--test-target` sweep isn't penalized for
    ///    legitimately taking a while between individual events.
    private func consume(
        session: TestManagerdSession,
        connection: Connection,
        reportDir: URL?
    ) async throws -> RunOutcome {
        let watchdog = IdleWatchdog()
        return try await withThrowingTaskGroup(of: RunOutcome.self) { group in
            group.addTask {
                var testCases: [TestCaseReport] = []
                var suiteFinished: (runCount: Int, failureCount: Int)?
                for await event in await session.events {
                    await watchdog.poke()
                    switch event {
                    case .testBundleReady:
                        print("Test bundle ready, starting execution...")
                    case .logDebugMessage(let message):
                        print("[debug] \(message)")
                    case .testCaseResult(let testClass, let testMethod, let status, let duration, let failureMessages):
                        print("[\(status.rawValue)] \(testClass)/\(testMethod) (\(String(format: "%.3f", duration))s)")
                        var screenshotPath: String?
                        if status == .failed, screenshotOnFailure, let reportDir {
                            // Best-effort: confirmed against real hardware (this session) that
                            // `com.apple.mobile.screenshotr` can fail with "Invalid service" on a
                            // device using a *personalized* iOS 17+ DDI fetched from this
                            // project's current source (`doronz88/DeveloperDiskImage`) -- the
                            // same failure reproduces with the stock `idevicescreenshot` CLI
                            // against the same device, and the identical code path succeeds
                            // against a classic (pre-17) DDI, so this is a DDI-content gap in the
                            // fetched personalized image, not a bug in `ScreenshotClient`. Not
                            // worth failing the whole run over.
                            screenshotPath = try? await captureScreenshot(
                                connection: connection,
                                reportDir: reportDir,
                                testClass: testClass,
                                testMethod: testMethod
                            )
                        }
                        testCases.append(TestCaseReport(
                            testClass: testClass,
                            testMethod: testMethod,
                            status: status,
                            duration: duration,
                            failureMessages: failureMessages,
                            screenshotPath: screenshotPath
                        ))
                    case .testSuiteFinished(let runCount, let failureCount):
                        // See `TestManagerdEvent.testSuiteFinished`'s doc comment: this is
                        // authoritative the first time it fires, regardless of how many
                        // `.testCaseResult` events we've collected so far -- trusted as-is rather
                        // than waited on to corroborate our own tally.
                        suiteFinished = (runCount, failureCount)
                        return RunOutcome(testCases: testCases, timedOutWithoutResult: false)
                    case .raw(let selector, let arguments):
                        // Anything not specifically handled above surfaces here so it's at least
                        // visible.
                        print("[\(selector)] \(arguments)")
                    }
                }
                _ = suiteFinished // silence unused-when-loop-exits-early warning; see above
                return RunOutcome(testCases: testCases, timedOutWithoutResult: true)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: .max)
                return RunOutcome(testCases: [], timedOutWithoutResult: true)
            }
            group.addTask {
                let pollInterval = 5.0
                while true {
                    try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    if await watchdog.secondsSinceLastEvent() > Double(self.sessionTimeout) {
                        return RunOutcome(testCases: [], timedOutWithoutResult: true)
                    }
                }
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func captureScreenshot(
        connection: Connection,
        reportDir: URL,
        testClass: String,
        testMethod: String
    ) async throws -> String {
        let screenshotr = try ScreenshotClient(connection: connection)
        let data = try screenshotr.takeScreenshot()
        let filename = "\(testClass)-\(testMethod)-\(Int(Date().timeIntervalSince1970)).png"
        let sanitized = filename.replacingOccurrences(of: "/", with: "_")
        try data.write(to: reportDir.appendingPathComponent(sanitized))
        return sanitized
    }

    /// Best-effort: `CrashLogClient` itself can fail to start (e.g. no Developer Disk Image, or
    /// simply no crash log service on this iOS version) without failing the run over it -- crash
    /// logs are a bonus artifact, not something `xtool test`'s pass/fail result should depend on.
    /// Filters to files whose name contains one of `processNames` (the runner product name and/or
    /// the target app's last bundle-ID component) and whose modification time (`st_mtime`, if AFC
    /// reports one) is no earlier than `since` -- best-effort on both counts, since a crash log
    /// worth surfacing but failing either heuristic is a worse outcome than one falsely included.
    private func collectCrashLogs(
        connection: Connection,
        reportDir: URL,
        runLabel: String,
        since: Date,
        processNames: [String]
    ) -> [String] {
        guard !processNames.isEmpty, let client = try? CrashLogClient(connection: connection) else { return [] }
        guard let names = try? client.listCrashReports() else { return [] }

        var collected: [String] = []
        for name in names {
            guard processNames.contains(where: { name.contains($0) }) else { continue }
            if let info = try? client.fileInfo(for: name),
               let mtimeString = info["st_mtime"],
               let mtimeNanos = Double(mtimeString) {
                let mtime = Date(timeIntervalSince1970: mtimeNanos / 1_000_000_000)
                guard mtime >= since else { continue }
            }
            guard let data = try? client.readCrashReport(name) else { continue }
            let sanitized = "\(runLabel)-\(name)".replacingOccurrences(of: "/", with: "_")
            guard (try? data.write(to: reportDir.appendingPathComponent(sanitized))) != nil else { continue }
            collected.append(sanitized)
        }
        return collected
    }
}

/// Captures the device syslog for the duration of a run via `syslog_relay`, writing it to the
/// report directory on `stop()`. Best-effort: a failure to start capture (e.g. service
/// unavailable) shouldn't fail the test run itself, so `TestCommand` only ever uses `try?` around
/// construction.
private actor SyslogCapture {
    private let client: SyslogRelayClient
    private var lines: [String] = []
    private var task: Task<Void, Never>?

    init(connection: Connection) async throws {
        let device = await connection.device
        self.client = try SyslogRelayClient(device: device, label: "xtool-test-syslog")
        task = Task { [weak self] in
            guard let self else { return }
            for await line in self.client.lines() {
                await self.append(line)
            }
        }
    }

    private func append(_ line: String) {
        lines.append(line)
    }

    func stop() {
        task?.cancel()
        client.stop()
    }

    /// Writes accumulated lines to `<reportDir>/<runLabel>-syslog.txt`, returning the filename
    /// (relative to `reportDir`) if a directory was provided and the write succeeded.
    func stop(into reportDir: URL?, runLabel: String) -> String? {
        stop()
        guard let reportDir else { return nil }
        let filename = "\(runLabel)-syslog.txt"
        let text = lines.joined(separator: "\n")
        guard (try? text.write(to: reportDir.appendingPathComponent(filename), atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return filename
    }
}
