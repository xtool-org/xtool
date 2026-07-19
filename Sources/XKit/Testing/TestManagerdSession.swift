//
//  TestManagerdSession.swift
//  XKit
//
//  Orchestrates the full handshake Xcode performs to run an installed XCTest bundle without
//  Xcode: two `testmanagerd` DTX sessions (one for authorization, one to drive test execution)
//  plus a third `instruments` DTX session to actually launch the Runner process, tied together
//  by writing an `XCTestConfiguration` plist into the Runner app's sandbox over house_arrest/AFC.
//  Selector names, channel names, and call sequence transcribed from the documented, working
//  reference implementation in appium-ios-device's `lib/xctest.js` (Apache-2.0 -- read for the
//  handshake sequence, rewritten from scratch in Swift here).
//
//  Requires the Developer Disk Image to already be mounted (see DDIMounter/PersonalizedDDIMounter)
//  -- testmanagerd/instruments are developer-only services exposed only once it is.

import Foundation
import SwiftyMobileDevice
import libimobiledevice
import plist

public enum TestManagerdEvent: Sendable {
    /// A `_XCT_...` callback from the device that isn't specifically interpreted below, exposed
    /// for callers (e.g. a future CLI reporter) that want to inspect raw test-progress calls.
    case raw(selector: String, arguments: [NSKeyedValue])
    case testBundleReady
    case logDebugMessage(String)
    /// `_XCT_testSuiteWithIdentifier:didFinishAt:runCount:skipCount:failureCount:
    /// expectedFailureCount:uncaughtExceptionCount:testDuration:totalDuration:` -- fires once per
    /// nesting level of the suite hierarchy (method's class, module, "All tests" root all report
    /// the same final tally once every test has finished, confirmed against real hardware), not
    /// once overall. There's no separate "run finished" signal to wait for instead: real hardware
    /// testing (this session) showed the runner logging "Creating future for 'confirming end of
    /// session with the harness' with timeout 1800.00" after results are already fully in, and
    /// no further callback (a `_XCT_didFinishExecutingTestPlan` was hypothesized and searched for
    /// specifically -- never observed) arrives to resolve that wait; it just sits there for up to
    /// 30 minutes. Also reachable via `TestOutputParser`'s stdout-parsed fallback (see
    /// `.testCaseResult`'s doc comment) for real-device cases where this structured callback never
    /// arrives at all even though the run completed -- callers should trust whichever arrives
    /// first as authoritative, not wait to corroborate it against accumulated `.testCaseResult`
    /// counts.
    case testSuiteFinished(runCount: Int, failureCount: Int)
    /// Parsed from the runner's own console output (`outputReceived:fromProcess:atTime:`), not a
    /// structured DTX callback -- see `TestOutputParser`'s header comment for why this is the
    /// reliable source of human-readable test names. `failureMessages` is always empty for
    /// `.passed`; for `.failed` it's the `<file>:<line>: error: ...` lines that preceded this
    /// test case's "failed" line, if any arrived.
    case testCaseResult(
        testClass: String,
        testMethod: String,
        status: TestCaseStatus,
        duration: Double,
        failureMessages: [String]
    )
}

public actor TestManagerdSession {

    public enum SessionError: Swift.Error, LocalizedError {
        case noServiceAvailable(String)
        case invalidRunnerBundle(String)
        case launchFailed(String)
        case missingLaunchedProcessID

        public var errorDescription: String? {
            switch self {
            case .noServiceAvailable(let name): "Could not start service '\(name)' (is the DDI mounted?)"
            case .invalidRunnerBundle(let reason): "Invalid XCTest runner bundle: \(reason)"
            case .launchFailed(let reason): "Failed to launch the test runner: \(reason)"
            case .missingLaunchedProcessID: "Device did not return a process ID for the launched runner"
            }
        }
    }

    private enum ServiceName {
        static let testmanagerdSecure = "com.apple.testmanagerd.lockdown.secure"
        static let testmanagerdLegacy = "com.apple.testmanagerd.lockdown"
        static let instrumentsSecure = "com.apple.instruments.remoteserver.DVTSecureSocketProxy"
        static let instrumentsLegacy = "com.apple.instruments.remoteserver"
    }

    private enum Channel {
        static let daemonConnectionInterface =
            "dtxproxy:XCTestManager_IDEInterface:XCTestManager_DaemonConnectionInterface"
        static let processControl = "com.apple.instruments.server.services.processcontrol"
    }

    /// `_IDE_startExecutingTestPlanWithProtocolVersion:` is sent to this literal channel code
    /// (0xFFFFFFFF as a two's-complement `Int32`), not the code `makeChannel` returns for
    /// `daemonConnectionInterface` -- confirmed against appium-ios-device's `MAGIC_CHANNEL`
    /// constant. This assumes `daemonConnectionInterface` is the only (and therefore first,
    /// code-1) channel opened on the exec-plan connection, which this type always does.
    private static let magicChannel: Int32 = -1
    private static let xcodeVersion: Int32 = 36
    private static let xcodeBuildPathMarker = "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"

    private let connection: Connection
    private let device: Device
    private let majorOSVersion: Int
    private let tunnelContext: TunnelContext?

    private var initialControlSession: DTXConnection?
    private var execTestPlanSession: DTXConnection?
    private var instrumentSession: DTXConnection?
    private var didStartExecutingTestPlan = false
    /// The runner process `launchRunner` started, so `stop()` can kill it -- otherwise it's left
    /// running on the device after every `xtool test` invocation (there's no completion detection
    /// yet, so every run ends via cancellation, not a natural exit), forcing a manual force-quit
    /// before the next run.
    private var launchedRunnerPID: pid_t?
    /// Set by `start()` when driving a separate target app (XCUITest), so `stop()` can terminate
    /// it too -- otherwise the target app is left running/foregrounded on the device after every
    /// `xtool test` invocation, exactly like `launchedRunnerPID`'s doc comment describes for the
    /// runner itself. Confirmed necessary against real hardware (this session): killing only the
    /// runner process leaves the target app sitting open on-screen, requiring a manual force-quit.
    private var targetApplicationBundleID: String?
    /// Passively captured from `_XCT_applicationDidUpdateState:` text that already flows through
    /// `_XCT_logDebugMessage:` during a normal run (e.g. "XTL-....MyApp@/private/var/...
    /// processName: MyApp pid: 82587 state: running foreground") -- used by `stop()` as a fast
    /// path instead of a live `processIdentifierForBundleIdentifier:` lookup. Confirmed against
    /// real hardware (this session): that lookup call consistently takes ~18s to reply (unrelated
    /// to whether the runner has already been killed -- an earlier fix reordering the calls to
    /// query before killing the runner made no difference), which is the actual source of the
    /// "target app closes, but with a big delay" symptom, since the kill can't be sent until the
    /// pid is known. This is best-effort: if the text was never observed (e.g. `stop()` is called
    /// very early, before the target app ever reported a state update), `stop()` falls back to
    /// the slow live lookup rather than skipping the kill entirely.
    private var lastKnownTargetApplicationPID: pid_t?
    /// `<file>:<line>: error: ...` lines parsed from console output, buffered per "Class method"
    /// key until the matching `.failed` test-case-finished line arrives to attach them to --
    /// see `TestOutputParser`'s header comment for why this parsing exists at all.
    private var pendingFailureMessages: [String: [String]] = [:]

    private var eventContinuation: AsyncStream<TestManagerdEvent>.Continuation?
    public let events: AsyncStream<TestManagerdEvent>

    /// iOS 17.4+'s RSD-discovered equivalents of the classic lockdown service names -- both
    /// `testmanagerd` connections (control + exec) go to the same service, matching the classic
    /// path's own `ServiceName.testmanagerdSecure`/`Legacy` reuse across both.
    private enum RSDServiceName {
        static let testmanagerd = "com.apple.dt.testmanagerd.remote"
        static let instruments = "com.apple.instruments.dtservicehub"
        static let appservice = "com.apple.coredevice.appservice"
    }

    /// Bundles the tunnel + its RSD service directory, when opening DTX connections via the
    /// iOS 17.4+ tunnel path (`RSDServiceName`) instead of classic lockdown (`ServiceName`).
    public struct TunnelContext: Sendable {
        let tunnel: CoreDeviceProxyTunnel
        let rsd: RSDHandshakeResponse

        public init(tunnel: CoreDeviceProxyTunnel, rsd: RSDHandshakeResponse) {
            self.tunnel = tunnel
            self.rsd = rsd
        }
    }

    /// - Parameter tunnel: when non-nil, DTX connections (testmanagerd, instruments) are opened
    ///   over this iOS 17.4+ RSD tunnel instead of classic lockdown -- everything else (house_arrest/
    ///   AFC for `XCTestConfiguration`, process control) still goes through `connection`/`device`
    ///   as before, since those aren't DTX and classic lockdown reaches them on every iOS version.
    public init(connection: Connection, productVersion: String, tunnel: TunnelContext? = nil) {
        self.connection = connection
        self.device = connection.device
        self.majorOSVersion = Int(productVersion.split(separator: ".").first ?? "0") ?? 0
        self.tunnelContext = tunnel
        var continuation: AsyncStream<TestManagerdEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    deinit {
        eventContinuation?.finish()
    }

    public func stop() async {
        // Each of these three is independent (a different DTX connection/service), so they run
        // concurrently rather than sequentially -- confirmed against real hardware (this session)
        // that two of them are each independently slow (the `processIdentifierForBundleIdentifier:`
        // lookup below consistently takes ~15-18s to reply regardless of call ordering, and
        // `execTestPlanSession.close()` separately takes ~13-15s), and running them one after
        // another was the real source of the "target app closes, but with a big delay" symptom --
        // concurrently, the total is bounded by the slower of the two instead of their sum.
        async let instrumentCleanup: Void = cleanUpInstrumentSession()
        async let closedInitial: Void = closeIfPresent(initialControlSession)
        async let closedExecPlan: Void = closeIfPresent(execTestPlanSession)
        _ = await (instrumentCleanup, closedInitial, closedExecPlan)
        eventContinuation?.finish()
    }

    private func closeIfPresent(_ session: DTXConnection?) async {
        await session?.close()
    }

    private func cleanUpInstrumentSession() async {
        guard let instrumentSession else { return }
        // Best-effort fast path: if a `_XCT_applicationDidUpdateState:` line for the target app
        // happened to arrive during the run (see `lastKnownTargetApplicationPID`'s doc comment),
        // this avoids the slow live lookup entirely -- not relied upon, since it's not guaranteed
        // to have arrived (confirmed against real hardware, this session: some runs simply never
        // report a state update for the target app specifically, only the runner's own).
        var targetApplicationPID = lastKnownTargetApplicationPID
        if targetApplicationPID == nil, let targetApplicationBundleID {
            var lookupAux = DTXAuxiliaryBuffer()
            lookupAux.append(.object(.string(targetApplicationBundleID)))
            if let reply = try? await instrumentSession.callChannel(
                Channel.processControl,
                selector: "processIdentifierForBundleIdentifier:",
                auxiliary: lookupAux
            ), case .int(let pid64)? = reply.payload, pid64 > 0 {
                targetApplicationPID = pid_t(pid64)
            }
        }
        if let targetApplicationPID {
            await kill(pid: targetApplicationPID, on: instrumentSession)
        }
        if let launchedRunnerPID {
            await kill(pid: launchedRunnerPID, on: instrumentSession)
        }
        await instrumentSession.close()
    }

    private func kill(pid: pid_t, on session: DTXConnection) async {
        var aux = DTXAuxiliaryBuffer()
        aux.append(.object(.int(Int64(pid))))
        _ = try? await session.callChannel(
            Channel.processControl,
            selector: "killPid:",
            auxiliary: aux,
            expectsReply: false
        )
    }

    /// Starts a lockdown service by raw string identifier. `SwiftyMobileDevice` (as pinned by
    /// this project) only exposes a generic `startService<T: LockdownService>(...)` overload
    /// keyed by a typed client -- there's no typed client for DTX services (see this file's
    /// header comment), so this calls the underlying `lockdownd_start_service`/
    /// `lockdownd_start_service_with_escrow_bag` C functions directly, exactly like
    /// `LockdownClient.ServiceDescriptor`'s generic initializer does internally, then wraps the
    /// result in the same public `ServiceDescriptor` type.
    private func startService(named identifier: String, sendEscrowBag: Bool = false) throws -> LockdownClient.ServiceDescriptor {
        var descriptor: lockdownd_service_descriptor_t?
        let fn = sendEscrowBag ? lockdownd_start_service_with_escrow_bag : lockdownd_start_service
        let status = fn(connection.client.raw, identifier, &descriptor)
        guard status == LOCKDOWN_E_SUCCESS, let descriptor else {
            throw SessionError.noServiceAvailable(identifier)
        }
        return LockdownClient.ServiceDescriptor(raw: descriptor)
    }

    /// Opens a service by its modern ("secure") name, falling back to the legacy name for older
    /// iOS versions that don't have the `DVTSecureSocketProxy`/`.secure` variant -- or, when
    /// `tunnelContext` is set, opens `rsdServiceName` over the iOS 17.4+ RSD tunnel instead. Either
    /// way the result is a `DTXConnection`; the DTX wire protocol above it doesn't know or care
    /// which transport it's running over.
    private func openDTXConnection(secureName: String, legacyName: String, rsdServiceName: String) throws -> DTXConnection {
        if let tunnelContext {
            guard let port = tunnelContext.rsd.port(for: rsdServiceName) else {
                throw SessionError.noServiceAvailable(rsdServiceName)
            }
            let transport = try TunnelDTXTransport(tunnel: tunnelContext.tunnel, port: port)
            return DTXConnection(transport: transport)
        }

        let descriptor: LockdownClient.ServiceDescriptor
        do {
            descriptor = try startService(named: secureName)
        } catch {
            do {
                descriptor = try startService(named: legacyName)
            } catch {
                throw SessionError.noServiceAvailable(legacyName)
            }
        }
        let transport = try DTXTransport.connect(device: device, service: descriptor)
        return DTXConnection(transport: transport)
    }

    // MARK: - Handshake

    /// Runs the full handshake and launches `runnerBundleID` (a pre-installed `Runner.app`
    /// containing the `.xctest` bundle to run). `targetApplicationBundleID` should be set for
    /// XCUITest runs that drive a separate app-under-test; leave `nil` for plain XCTest bundles
    /// hosted directly inside the runner.
    ///
    /// - Parameter testBundleName: the `.xctest` bundle's name (without extension) inside the
    ///   runner's `PlugIns/` directory, e.g. `Plan.XCTestPlan.testProductName`. Real Xcode-built
    ///   runners derive this from their own executable name by stripping a `-Runner` suffix
    ///   (`MyAppTests-Runner` -> `MyAppTests`); xtool's synthesized runners don't follow that
    ///   naming convention (confirmed against a real device that assuming they did was a real
    ///   bug), so this must be passed explicitly instead of derived from `runnerBundleID`'s
    ///   executable name.
    @discardableResult
    public func start(
        runnerBundleID: String,
        testBundleName: String,
        targetApplicationBundleID: String? = nil,
        testsToRun: [String]? = nil,
        testsToSkip: [String]? = nil
    ) async throws -> pid_t {
        let sessionIdentifier = UUID()

        try await startInitialControlSession()
        try await startExecTestPlanSession(sessionIdentifier: sessionIdentifier)

        let pid = try await launchRunner(
            bundleID: runnerBundleID,
            testBundleName: testBundleName,
            targetApplicationBundleID: targetApplicationBundleID,
            sessionIdentifier: sessionIdentifier,
            testsToRun: testsToRun,
            testsToSkip: testsToSkip
        )
        launchedRunnerPID = pid
        self.targetApplicationBundleID = targetApplicationBundleID

        try await authorizeTestSession(processID: pid)

        // Real hardware testing (iOS 16.7, this session) showed the runner process staying alive
        // indefinitely, past its own initial `XCTTargetBootstrap` checks, with neither
        // `_XCT_testBundleReadyWithProtocolVersion:minimumVersion:` nor a matching
        // `_XCT_logDebugMessage:` (this file's two existing triggers, transcribed from
        // appium-ios-device's `_startExecSession`) ever arriving to fire
        // `startExecutingTestPlanIfNeeded` -- no crash, no error, just silence. pymobiledevice3's
        // `XCUITestService.run` (a separately-maintained, actively-used reference; read for
        // control flow only, not copied -- see this file's header comment) does not gate sending
        // `_IDE_startExecutingTestPlanWithProtocolVersion:` on any `_XCT_...` callback from the
        // runner at all -- it sends it as soon as authorization succeeds (immediately after
        // opening the runner's reverse DTX channel, which this implementation doesn't track
        // separately since `_IDE_startExecutingTestPlanWithProtocolVersion:` already goes out on
        // the fixed "magic channel", not a negotiated one). Calling this here proactively, in
        // addition to (not instead of) the existing selector-triggered calls: harmless if the
        // runner does send one of those triggers later (`startExecutingTestPlanIfNeeded` is
        // idempotent, guarded by `didStartExecutingTestPlan`), and unblocks the case -- not yet
        // confirmed but consistent with everything observed -- where the runner is itself waiting
        // for this call before doing anything else observable.
        if let execTestPlanSession {
            await startExecutingTestPlanIfNeeded(on: execTestPlanSession)
        }

        return pid
    }

    /// Builds an `XCTCapabilities` archive object: `{"capabilities-dictionary": <dict>}`, class
    /// `XCTCapabilities`/`NSObject`. Wire shape confirmed against go-ios's `nskeyedarchiver.
    /// XCTCapabilities`/`archiveXCTCapabilities` (MIT -- read for the field layout only, not
    /// copied; see this file's header comment).
    private static func capabilities(_ dict: [String: NSKeyedValue] = [:]) -> NSKeyedValue {
        .object(className: "XCTCapabilities", properties: [
            ("capabilities-dictionary", .dictionary(dict)),
        ])
    }

    private func startInitialControlSession() async throws {
        let dtx = try openDTXConnection(secureName: ServiceName.testmanagerdSecure, legacyName: ServiceName.testmanagerdLegacy, rsdServiceName: RSDServiceName.testmanagerd)
        await dtx.start()
        initialControlSession = dtx

        guard majorOSVersion >= 11 else { return }
        var aux = DTXAuxiliaryBuffer()
        // `_IDE_initiateControlSessionWithCapabilities:` for iOS 14+, matching go-ios's
        // `runXUITestWithBundleIdsXcode12Ctx` (its actual working iOS 14-16 implementation, not
        // just the iOS 17+ path) -- confirmed necessary against real hardware (iOS 16.7): the
        // legacy `_IDE_initiateControlSessionWithProtocolVersion:` this code originally sent
        // (transcribed from appium-ios-device) got a normal-looking reply and let the exec-plan
        // session reach "waiting to pair", but the on-device test runner then never opened its
        // own channel or sent any further DTX traffic at all -- consistent with testmanagerd
        // internally treating a capabilities-initiated session differently from a
        // protocol-version-initiated one, not just accepting either as equivalent. iOS 11-13 keep
        // the protocol-version selector (pymobiledevice3 confirms that range still uses it; no
        // go-ios reference or real device available to verify differently for that older range).
        if majorOSVersion >= 14 {
            aux.append(.object(Self.capabilities()))
            _ = try await dtx.callChannel(
                Channel.daemonConnectionInterface,
                selector: "_IDE_initiateControlSessionWithCapabilities:",
                auxiliary: aux
            )
        } else {
            aux.append(.object(.int(Int64(Self.xcodeVersion))))
            _ = try await dtx.callChannel(
                Channel.daemonConnectionInterface,
                selector: "_IDE_initiateControlSessionWithProtocolVersion:",
                auxiliary: aux
            )
        }
    }

    private func startExecTestPlanSession(sessionIdentifier: UUID) async throws {
        let dtx = try openDTXConnection(secureName: ServiceName.testmanagerdSecure, legacyName: ServiceName.testmanagerdLegacy, rsdServiceName: RSDServiceName.testmanagerd)
        await dtx.start()
        execTestPlanSession = dtx

        // ensures daemonConnectionInterface is channel code 1, matching Self.magicChannel's
        // hardcoded assumption (see its doc comment).
        _ = try await dtx.makeChannel(Channel.daemonConnectionInterface)

        await dtx.onSelector("_XCT_testBundleReadyWithProtocolVersion:minimumVersion:") { [weak self] _ in
            Task {
                await self?.emit(.testBundleReady)
                await self?.startExecutingTestPlanIfNeeded(on: dtx)
            }
        }
        await dtx.onSelector("_XCT_logDebugMessage:") { [weak self] message in
            // `message.payload` is the selector name itself ("_XCT_logDebugMessage:"), not the
            // logged text -- that's in the first auxiliary argument. Confirmed as a real,
            // previously-unnoticed bug once real callback traffic finally arrived on real
            // hardware (this session): every `.logDebugMessage` event was showing the literal
            // string "_XCT_logDebugMessage:" instead of the runner's actual log line.
            guard case .object(.string(let text))? = message.auxiliary.values.first else { return }
            Task {
                await self?.emit(.logDebugMessage(text))
                if text.contains("Received test runner ready reply with error: (null") {
                    await self?.startExecutingTestPlanIfNeeded(on: dtx)
                }
                await self?.captureTargetApplicationPID(fromLogText: text)
            }
        }
        await dtx.onSelector(
            "_XCT_testSuiteWithIdentifier:didFinishAt:runCount:skipCount:failureCount:"
                + "expectedFailureCount:uncaughtExceptionCount:testDuration:totalDuration:"
        ) { [weak self] message in
            // Positional: [runCount, skipCount, failureCount, expectedFailureCount,
            // uncaughtExceptionCount] -- the leading `didFinishAt` date string and trailing
            // duration doubles aren't ints, so filtering to just `.int` values conveniently
            // lines them up at indices 0/1/2 regardless of whether the leading identifier
            // argument (a numeric/opaque value in this protocol version, not a human-readable
            // name) is present in this buffer.
            let ints: [Int64] = message.auxiliary.values.compactMap {
                if case .object(.int(let i)) = $0 { return i }
                return nil
            }
            guard ints.count >= 3 else { return }
            let runCount = Int(ints[0])
            let failureCount = Int(ints[2])
            Task { await self?.emit(.testSuiteFinished(runCount: runCount, failureCount: failureCount)) }
        }
        await dtx.onUnhandled { [weak self] message in
            // catch-all: any other `_XCT_...` selector not specifically handled above.
            guard case .string(let selector)? = message.payload else { return }
            let arguments: [NSKeyedValue] = message.auxiliary.values.compactMap {
                if case .object(let value) = $0 { return value }
                return nil
            }
            Task { await self?.emit(.raw(selector: selector, arguments: arguments)) }
        }

        let sessionUUID = NSKeyedValue.object(className: "NSUUID", properties: [
            ("NS.uuidbytes", .data(sessionIdentifier.dtxUUIDBytes)),
        ])
        var aux = DTXAuxiliaryBuffer()
        // `_IDE_initiateSessionWithIdentifier:capabilities:` for iOS 14+ -- see
        // `startInitialControlSession`'s doc comment for why (same real-hardware finding, same
        // go-ios reference). Capability keys match go-ios's `runXUITestWithBundleIdsXcode12Ctx`
        // (iOS 14-16) exactly for that range; iOS 17+ gets go-ios's larger
        // `runXUITestWithBundleIdsXcode15Ctx` set instead -- notably including "daemon container
        // sandbox extension", missing from the 14-16 set. Real-hardware testing (iPhone 17 Pro,
        // iOS 26, this session) showed testmanagerd accepting this call and then hanging forever
        // at "Waiting for harness to handle response to session initiation before notifying
        // delegate" with the smaller (14-16) capability set -- consistent with testmanagerd
        // requiring the caller to have declared a capability it isn't otherwise willing to grant.
        if majorOSVersion >= 17 {
            aux.append(.object(sessionUUID))
            aux.append(.object(Self.capabilities([
                "XCTIssue capability": .int(1),
                "daemon container sandbox extension": .int(1),
                "delayed attachment transfer": .int(1),
                "expected failure test capability": .int(1),
                "request diagnostics for specific devices": .int(1),
                "skipped test capability": .int(1),
                "test case run configurations": .int(1),
                "test iterations": .int(1),
                "test timeout capability": .int(1),
                "ubiquitous test identifiers": .int(1),
            ])))
            _ = try await dtx.callChannel(
                Channel.daemonConnectionInterface,
                selector: "_IDE_initiateSessionWithIdentifier:capabilities:",
                auxiliary: aux
            )
        } else if majorOSVersion >= 14 {
            aux.append(.object(sessionUUID))
            aux.append(.object(Self.capabilities([
                "XCTIssue capability": .int(1),
                "skipped test capability": .int(1),
                "test timeout capability": .int(1),
            ])))
            _ = try await dtx.callChannel(
                Channel.daemonConnectionInterface,
                selector: "_IDE_initiateSessionWithIdentifier:capabilities:",
                auxiliary: aux
            )
        } else {
            aux.append(.object(sessionUUID))
            aux.append(.object(.string("\(sessionIdentifier.uuidString)-746F-006D726964646C79")))
            aux.append(.object(.string(Self.xcodeBuildPathMarker)))
            aux.append(.object(.int(Int64(Self.xcodeVersion))))
            _ = try await dtx.callChannel(
                Channel.daemonConnectionInterface,
                selector: "_IDE_initiateSessionWithIdentifier:forClient:atPath:protocolVersion:",
                auxiliary: aux
            )
        }
    }

    private struct AppLookupInfo {
        let container: String
        let path: String
    }

    /// Looks up `Container`/`Path` for an installed app via a direct
    /// `instproxy_lookup` call, bypassing `InstallationProxyClient.lookup`'s generic
    /// `Decodable`-based path entirely.
    ///
    /// - Important: `InstallationProxyClient.lookup` (pinned `SwiftyMobileDevice` 1.5.0) crashes
    ///   natively (a real SIGSEGV inside libplist's decode path, not a Swift-level error) when
    ///   called from this file -- confirmed reproducible against a real device across multiple
    ///   independent runs, with two different bundle IDs, and unaffected by narrowing
    ///   `returnAttributes`. Root cause not isolated (no symbols in the crashing native frames).
    ///   This works around it by using the same lower-level pattern already used elsewhere in
    ///   this file for calls `SwiftyMobileDevice` doesn't wrap (raw C call + the `PlistValue`
    ///   bridge from Phase 0's `PersonalizedDDIMounter` work), rather than the generic decoder.
    private func lookupApp(bundleID: String, client: InstallationProxyClient) throws -> AppLookupInfo {
        let optionsPlist = PlistValue.dictionary([
            "ReturnAttributes": .array([.string("Container"), .string("Path")]),
        ]).toPlistT()
        defer { plist_free(optionsPlist) }

        var appIDs: [UnsafeMutablePointer<CChar>?] = [strdup(bundleID), nil]
        defer { appIDs.forEach { $0.map { free($0) } } }

        var result: plist_t?
        let status = appIDs.withUnsafeMutableBufferPointer { buf -> instproxy_error_t in
            buf.withMemoryRebound(to: UnsafePointer<CChar>?.self) { rebound in
                instproxy_lookup(client.raw, rebound.baseAddress, optionsPlist, &result)
            }
        }
        guard status == INSTPROXY_E_SUCCESS, let result else {
            throw SessionError.invalidRunnerBundle("'\(bundleID)' is not installed")
        }
        defer { plist_free(result) }

        guard case .dictionary(let apps) = PlistValue(plistT: result),
              case .dictionary(let info)? = apps[bundleID],
              case .string(let container)? = info["Container"],
              case .string(let path)? = info["Path"]
        else {
            throw SessionError.invalidRunnerBundle("'\(bundleID)' is not installed")
        }
        return AppLookupInfo(container: container, path: path)
    }

    private func launchRunner(
        bundleID: String,
        testBundleName: String,
        targetApplicationBundleID: String?,
        sessionIdentifier: UUID,
        testsToRun: [String]?,
        testsToSkip: [String]?
    ) async throws -> pid_t {
        let installProxy: InstallationProxyClient = try await connection.startClient()
        let appInfo = try lookupApp(bundleID: bundleID, client: installProxy)
        // For an XCUITest run, the runner needs the target app's *actual* install path to
        // correlate against -- left at `XCTestConfiguration`'s placeholder default (confirmed
        // against real hardware, this session), the runner never fails outright, it just never
        // recognizes the target app's process among the (mostly unrelated) accessibility
        // notifications it observes, so nothing ever progresses past "authorized, waiting."
        let targetApplicationPath = try targetApplicationBundleID.map {
            try lookupApp(bundleID: $0, client: installProxy).path
        }

        let sessionToken = sessionIdentifier.uuidString.uppercased()
        let xctestConfigRelativePath = "\(testBundleName)-\(sessionToken).xctestconfiguration"

        var config = XCTestConfiguration(
            testBundleURL: "file://\(appInfo.path)/PlugIns/\(testBundleName).xctest",
            sessionIdentifier: sessionIdentifier,
            productModuleName: testBundleName,
            targetApplicationBundleID: targetApplicationBundleID,
            targetApplicationPath: targetApplicationPath ?? "/KEEP-THIS-NOT-EMPTY/KEEP-THIS-NOT-EMPTY",
            testsToRun: testsToRun,
            testsToSkip: testsToSkip
        )
        // Only an actual XCUITest run (driving a separate target app) needs the automation/
        // accessibility bootstrap this triggers -- confirmed against real hardware (this session):
        // left at the struct's default `true` for a plain hosted XCTest run (no target app), the
        // runner spun forever repeating "getting screen bounds" against an automation session that
        // was never actually established, since there's no target app to automate.
        config.initializeForUITesting = targetApplicationBundleID != nil
        // Confirmed against pymobiledevice3's `to_xctestconfiguration`, which switches on this
        // same >= 17 threshold -- real-device evidence (this session): leaving this at the
        // pre-17 default on iOS 26 let the actual test case run and pass, but the runner's
        // post-test-case automation-session re-acquisition then failed with "No bundle at path
        // /Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework", stalling the
        // session instead of completing.
        if majorOSVersion >= 17 {
            config.automationFrameworkPath = "/System/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework"
        }
        let finalConfig = config
        try await writeConfiguration(finalConfig, relativePath: xctestConfigRelativePath, toSandboxOf: bundleID)

        // The on-device runner calls `_XCT_testRunnerReadyWithCapabilities:` back on the exec-plan
        // session once it's up, expecting the reply payload to actually *be* this configuration --
        // confirmed against go-ios's `proxydispatcher.go`, which suppresses the default ack for
        // this selector and replies with the archived `XCTestConfiguration` instead. Without this,
        // `XCTTargetBootstrap` never observes the test daemon as ready and the run hangs forever.
        // Registered here (not in `startExecTestPlanSession`) so the closure can capture `config`
        // directly -- it's a plain `Sendable` value, unlike this actor's other state, which would
        // need an `await` hop the synchronous reply-handler contract doesn't allow.
        if let execTestPlanSession {
            await execTestPlanSession.onSelectorWithReply("_XCT_testRunnerReadyWithCapabilities:") { _ in
                finalConfig.keyedValue
            }
        }

        let dtx = try openDTXConnection(secureName: ServiceName.instrumentsSecure, legacyName: ServiceName.instrumentsLegacy, rsdServiceName: RSDServiceName.instruments)
        await dtx.start()
        instrumentSession = dtx

        // Fallback completion signal: confirmed against real hardware (this session, XCUITest
        // against a real target app) that the exec-plan session's structured
        // `_XCT_testSuiteWithIdentifier:didFinishAt:...` callback can simply never arrive even
        // though the on-device run completes successfully -- the runner's stdout (relayed here
        // over this *separate* instruments connection, which keeps flowing even when the
        // exec-plan session goes silent) still prints XCTest's own human-readable summary line
        // ("Test Suite 'All tests' passed/failed at ...\n\t Executed N tests, with M failures
        // ..."), so this is parsed as a backstop in case the structured signal never shows up.
        await dtx.onSelector("outputReceived:fromProcess:atTime:") { [weak self] message in
            guard case .object(.string(let text))? = message.auxiliary.values.first else { return }
            Task { await self?.handleOutputText(text) }
        }

        var lookupAux = DTXAuxiliaryBuffer()
        lookupAux.append(.object(.string(bundleID)))
        _ = try? await dtx.callChannel(
            Channel.processControl,
            selector: "processIdentifierForBundleIdentifier:",
            auxiliary: lookupAux
        )

        let xctestConfigurationPath = appInfo.container + "/tmp/" + xctestConfigRelativePath
        var envStrings: [String: String] = [
            "CA_ASSERT_MAIN_THREAD_TRANSACTIONS": "0",
            "CA_DEBUG_TRANSACTIONS": "0",
            "DYLD_FRAMEWORK_PATH": "\(appInfo.path)/Frameworks:",
            "DYLD_LIBRARY_PATH": "\(appInfo.path)/Frameworks",
            "NSUnbufferedIO": "YES",
            "SQLITE_ENABLE_THREAD_ASSERTIONS": "1",
            "XCTestConfigurationFilePath": xctestConfigurationPath,
            "XCODE_DBG_XPC_EXCLUSIONS": "com.apple.dt.xctestSymbolicator",
            "LLVM_PROFILE_FILE": "\(appInfo.container)/tmp/%p.profraw",
            // Confirmed present in pymobiledevice3's `_generate_launch_args` (read for the
            // env-key set only, not copied -- see this file's header comment) and missing here
            // until now: without these two, the runner process launches and stays alive (past
            // the framework-embedding and UIApplicationMain fixes) but its XCTTargetBootstrap
            // subsystem never proceeds past its initial "test daemon not ready" checks -- it
            // never reads `XCTestConfigurationFilePath` at all without also being told the
            // bundle path and session identifier directly via these two keys.
            "XCTestBundlePath": "\(appInfo.path)/PlugIns/\(testBundleName).xctest",
            "XCTestSessionIdentifier": sessionToken,
        ]
        if majorOSVersion >= 11 {
            envStrings["DYLD_INSERT_LIBRARIES"] = "/Developer/usr/lib/libMainThreadChecker.dylib"
            envStrings["OS_ACTIVITY_DT_MODE"] = "YES"
        }
        let env = envStrings.mapValues { NSKeyedValue.string($0) }

        let argStrings = ["-NSTreatUnknownArgumentsAsOpen", "NO", "-ApplePersistenceIgnoreState", "YES"]
        let args: [NSKeyedValue] = argStrings.map { .string($0) }
        // `KillExisting: true` was tried (matching go-ios's `ProcessControl`'s use of the key) to
        // chase what was, at the time, misdiagnosed as a stale-process rejection -- the real cause
        // turned out to be the DTX auxiliary-buffer format bug documented on
        // `DTXAuxiliaryBuffer.encoded()` in `DTXMessage.swift`, unrelated to this. Reverted:
        // confirmed against real hardware that `true` here makes the on-device process-control
        // service perform a *separate* kill-then-relaunch (a distinct pid, launched by
        // DTServiceHub itself as "Terminating any existing instance before DTServiceHub app
        // launch" in the device syslog) rather than simply reusing/suppressing a duplicate --
        // and the freshly-relaunched instance never went on to log any `XCTTargetBootstrap`
        // activity the way a plain, single `KillExisting: false` launch reliably does. Matches
        // go-ios's own default (`uint64(0)`, i.e. false) for a plain app launch.
        // `ActivateSuspended` (foreground/activate the app once launched) is only sent for
        // XCUITest runs, matching go-ios's `startTestRunner17` exactly: it builds an *empty*
        // options dict for plain XCTest and only populates `ActivateSuspended`/
        // `__ActivateSuspended`/`StartSuspendedKey` when `!isXCTest` (i.e. XCUITest, which needs a
        // foregrounded, visible app to drive). This code previously sent `ActivateSuspended: true`
        // unconditionally for every run on iOS >= 12 -- untested previously whether forcing
        // foreground-activation on a plain XCTest run (which isn't supposed to need it at all)
        // could itself be why the runner never signals readiness back to testmanagerd.
        var options: [String: NSKeyedValue]
        if targetApplicationBundleID != nil && majorOSVersion >= 12 {
            options = [
                "ActivateSuspended": .int(1),
                "StartSuspendedKey": .int(0),
                "__ActivateSuspended": .int(1),
            ]
        } else {
            options = [
                "StartSuspendedKey": .bool(false),
                "KillExisting": .bool(false),
            ]
        }

        let pid: pid_t
        // On the iOS 17.4+ tunnel path, launch via `com.apple.coredevice.appservice` (RemoteXPC,
        // not DTX) instead of the classic DTX `processcontrol` channel below -- pymobiledevice3
        // (an independent implementation) hits the exact same "runner never signals readiness"
        // failure the DTX call produces, and go-ios's only working iOS 17+ path launches via this
        // appservice instead. A first attempt at this reused `envStrings` (the DTX path's env
        // dict) and got total silence back from the device -- go-ios's `startTestRunner17`
        // (finally read in full, not just skimmed) revealed the DDI/appservice launch path needs
        // an entirely different environment, not the DTX one: `DYLD_FRAMEWORK_PATH`/
        // `DYLD_LIBRARY_PATH` point at the *DDI's* system paths, not the app bundle;
        // `XCTestConfigurationFilePath` is left empty; `XCTestManagerVariant: "DDI"` is set (xtool
        // had none of this); and -- likely the actual missing piece for plain XCTest --
        // `DYLD_INSERT_LIBRARIES` must additionally include `libXCTestBundleInject.dylib`, the
        // actual dylib that triggers the on-device runtime to dlopen the `.xctest` bundle at all.
        // Always injected, not just for plain (hosted) XCTest: the runner always needs its
        // *own* `.xctest` bundle loaded regardless of whether it's testing itself or driving
        // a separate target app -- confirmed against real hardware (this session): an XCUITest
        // run (targetApplicationBundleID != nil) reproduced the exact same "authorizes, starts
        // executing the plan, then total silence" symptom plain XCTest had before this dylib
        // was added, with this one condition being the only difference. go-ios's own `isXCTest`
        // conditional for this (read as "plain XCTest only" when this was first written) may
        // reflect something else about go-ios's flow, not an actual iOS-side requirement to
        // omit it for XCUITest.
        //
        // On iOS 17+, launch via the *classic* DTX `processcontrol` channel (below, tunneled
        // through the same `dtx` connection already used for everything else in this method),
        // not `com.apple.coredevice.appservice` -- confirmed against pymobiledevice3's current
        // (actively maintained) `xcuitest.py`, which uses `launch_suspended_process` over the
        // DVT/instruments channel for *every* iOS version including 17+/26+, with no appservice
        // branch at all. This directly contradicts this file's prior assumption (that appservice
        // is the only working iOS 17+ path, based on a much older reading of go-ios) -- the
        // earlier real-device attempt at the classic path that motivated switching to appservice
        // predates both the `libXCTestBundleInject.dylib` and `targetApplicationPath` fixes above,
        // so its failure was likely caused by those missing pieces, not the launch mechanism
        // itself.
        if tunnelContext != nil {
            let ddiLibraries = "/Developer/usr/lib/libMainThreadChecker.dylib:/System/Developer/usr/lib/libXCTestBundleInject.dylib"
            let ddiEnvStrings: [String: String] = [
                "CA_ASSERT_MAIN_THREAD_TRANSACTIONS": "0",
                "CA_DEBUG_TRANSACTIONS": "0",
                "DYLD_INSERT_LIBRARIES": ddiLibraries,
                "DYLD_FRAMEWORK_PATH": "/System/Developer/Library/Frameworks",
                "DYLD_LIBRARY_PATH": "/System/Developer/usr/lib",
                "MTC_CRASH_ON_REPORT": "1",
                "NSUnbufferedIO": "YES",
                "OS_ACTIVITY_DT_MODE": "YES",
                "SQLITE_ENABLE_THREAD_ASSERTIONS": "1",
                "XCTestBundlePath": "\(appInfo.path)/PlugIns/\(testBundleName).xctest",
                "XCTestConfigurationFilePath": "",
                "XCTestManagerVariant": "DDI",
                "XCTestSessionIdentifier": sessionToken,
            ]
            let ddiEnv = ddiEnvStrings.mapValues { NSKeyedValue.string($0) }

            var launchAux = DTXAuxiliaryBuffer()
            launchAux.append(.object(.string(appInfo.path)))
            launchAux.append(.object(.string(bundleID)))
            launchAux.append(.object(.dictionary(ddiEnv)))
            launchAux.append(.object(.array(args)))
            launchAux.append(.object(.dictionary(options)))
            let launchReply = try await dtx.callChannel(
                Channel.processControl,
                selector: "launchSuspendedProcessWithDevicePath:bundleIdentifier:environment:arguments:options:",
                auxiliary: launchAux
            )
            guard case .int(let pid64)? = launchReply.payload else {
                throw SessionError.launchFailed("expected a process ID, got \(String(describing: launchReply.payload))")
            }
            pid = pid_t(pid64)
        } else {
            var launchAux = DTXAuxiliaryBuffer()
            launchAux.append(.object(.string(appInfo.path)))
            launchAux.append(.object(.string(bundleID)))
            launchAux.append(.object(.dictionary(env)))
            launchAux.append(.object(.array(args)))
            launchAux.append(.object(.dictionary(options)))
            let launchReply = try await dtx.callChannel(
                Channel.processControl,
                selector: "launchSuspendedProcessWithDevicePath:bundleIdentifier:environment:arguments:options:",
                auxiliary: launchAux
            )
            guard case .int(let pid64)? = launchReply.payload else {
                throw SessionError.launchFailed("expected a process ID, got \(String(describing: launchReply.payload))")
            }
            pid = pid_t(pid64)
        }

        var observeAux = DTXAuxiliaryBuffer()
        observeAux.append(.object(.int(Int64(pid))))
        _ = try? await dtx.callChannel(Channel.processControl, selector: "startObservingPid:", auxiliary: observeAux)

        return pid
    }

    private func authorizeTestSession(processID: pid_t) async throws {
        guard let dtx = initialControlSession else { throw SessionError.launchFailed("no control session") }
        var aux = DTXAuxiliaryBuffer()
        aux.append(.object(.int(Int64(processID))))
        if majorOSVersion >= 12 {
            _ = try await dtx.callChannel(
                Channel.daemonConnectionInterface,
                selector: "_IDE_authorizeTestSessionWithProcessID:",
                auxiliary: aux
            )
        } else if majorOSVersion <= 9 {
            _ = try await dtx.callChannel(
                Channel.daemonConnectionInterface,
                selector: "_IDE_initiateControlSessionForTestProcessID:",
                auxiliary: aux
            )
        } else {
            aux.append(.object(.int(Int64(Self.xcodeVersion))))
            _ = try await dtx.callChannel(
                Channel.daemonConnectionInterface,
                selector: "_IDE_initiateControlSessionForTestProcessID:protocolVersion:",
                auxiliary: aux
            )
        }
    }

    private func writeConfiguration(_ config: XCTestConfiguration, relativePath: String, toSandboxOf bundleID: String) async throws {
        let houseArrest: HouseArrestClient = try await connection.startClient()
        let afc = try houseArrest.vend(.container, forApp: bundleID)

        for existing in (try? afc.contentsOfDirectory(at: URL(fileURLWithPath: "/tmp"))) ?? [] {
            guard existing.hasSuffix(".xctestconfiguration") else { continue }
            try? afc.removeItem(at: URL(fileURLWithPath: "/tmp").appendingPathComponent(existing))
        }

        let destination = URL(fileURLWithPath: "/tmp").appendingPathComponent(relativePath)
        let file = try afc.open(destination, mode: .writeOnly)
        _ = try file.write(config.archived())
    }

    private func emit(_ event: TestManagerdEvent) {
        eventContinuation?.yield(event)
    }

    /// See `lastKnownTargetApplicationPID`'s doc comment. Matches lines of the shape
    /// "<bundleID>@<path> processName: <name> pid: <N> state: ..." -- only the pid immediately
    /// following "pid: " after confirming this line is actually about the target app (not some
    /// unrelated process the runner also happens to report on, e.g. the runner itself).
    private func captureTargetApplicationPID(fromLogText text: String) {
        guard let targetApplicationBundleID, text.contains("\(targetApplicationBundleID)@") else { return }
        guard let marker = text.range(of: " pid: ") else { return }
        let digits = text[marker.upperBound...].prefix { $0.isNumber }
        guard let pid = pid_t(digits) else { return }
        lastKnownTargetApplicationPID = pid
    }

    private func handleOutputText(_ text: String) {
        for outputEvent in TestOutputParser.parse(text) {
            switch outputEvent {
            case .testCaseStarted:
                break
            case .failureDetail(let testClass, let testMethod, let file, let line, let message):
                let key = "\(testClass) \(testMethod)"
                let location = [file, line.map(String.init)].compactMap { $0 }.joined(separator: ":")
                let full = location.isEmpty ? message : "\(location): \(message)"
                pendingFailureMessages[key, default: []].append(full)
            case .testCaseFinished(let testClass, let testMethod, let status, let duration):
                let key = "\(testClass) \(testMethod)"
                let failureMessages = pendingFailureMessages.removeValue(forKey: key) ?? []
                emit(.testCaseResult(
                    testClass: testClass,
                    testMethod: testMethod,
                    status: status,
                    duration: duration,
                    failureMessages: failureMessages
                ))
            case .suiteFinished(_, let runCount, let failureCount):
                emit(.testSuiteFinished(runCount: runCount, failureCount: failureCount))
            }
        }
    }

    /// Fires `_IDE_startExecutingTestPlanWithProtocolVersion:`, at most once
    /// (`didStartExecutingTestPlan` makes every call site idempotent). Three call sites feed into
    /// this: `_XCT_testBundleReadyWithProtocolVersion:minimumVersion:` or a matching
    /// `_XCT_logDebugMessage:` (both from `startExecTestPlanSession`'s handler registrations,
    /// transcribed from appium-ios-device), and unconditionally right after
    /// `_IDE_authorizeTestSessionWithProcessID:` succeeds in `start()` (matching
    /// pymobiledevice3's flow, which never waits on an `_XCT_...` callback at all -- see `start()`'s
    /// doc comment for why both are wired up).
    private func startExecutingTestPlanIfNeeded(on dtx: DTXConnection) async {
        guard !didStartExecutingTestPlan else { return }
        didStartExecutingTestPlan = true

        // Wait for the device to open its own channel first -- confirmed against real hardware
        // to be required (see `DTXConnection.waitForAnyDeviceChannelRequest`'s doc comment for
        // the full story); falls through and sends anyway on timeout rather than giving up
        // silently, in case this doesn't hold for some OS version/trigger path this wasn't tested
        // against.
        try? await dtx.waitForAnyDeviceChannelRequest()

        // Address the device's *actual* negotiated channel when we have it, not the hardcoded
        // `Self.magicChannel` -- see `DTXConnection.anyDeviceRequestedChannelCode`'s doc comment
        // for why. Negated: the device's own request (`_requestChannelWithCode:identifier:`)
        // reports its *local* view of the code (confirmed on real hardware to be `1`, matching
        // `daemonConnectionInterface`'s own client-opened channel code); addressing messages *to*
        // that channel from this side requires the negated value, per this same file's existing
        // `channelHandlers[-message.channelCode]` convention for the reverse direction. Sending on
        // the un-negated code silently went nowhere -- the runner logged "entering wait loop ...
        // requesting ready for testing" and never proceeded, even though the call itself
        // succeeded with no error. Un-negated, this coincidentally reproduces `Self.magicChannel`
        // (`-1`) whenever the device requests code `1`, which is presumably why go-ios's hardcoded
        // `-1` already worked without ever needing to look up the device's own requested code.
        let channelCode = await dtx.anyDeviceRequestedChannelCode().map { -$0 } ?? Self.magicChannel

        var aux = DTXAuxiliaryBuffer()
        aux.append(.object(.int(Int64(Self.xcodeVersion))))
        // A short delay before firing is documented as necessary on some devices/iOS versions
        // (appium-ios-device's comment: "if not using a delay this would fail on iPhone7 iOS
        // 13.6.1") -- kept here for the same reason.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        _ = try? await dtx.call(
            channelCode: channelCode,
            selector: "_IDE_startExecutingTestPlanWithProtocolVersion:",
            auxiliary: aux,
            expectsReply: false
        )
    }
}
