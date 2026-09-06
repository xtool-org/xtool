//
//  DTXConnection.swift
//  XKit
//
//  The channel/dispatch layer on top of DTXTransport + DTXMessage: opens named "channels" over a
//  single DTX socket (mirroring `DTXConnection`/`DTXChannel` in Apple's private
//  DTXConnectionServices framework), correlates request/reply pairs by message identifier, and
//  dispatches unsolicited device-initiated calls (e.g. `_XCT_testCaseDidFinishForTestClass:...`)
//  to registered handlers. Structured after the documented, working reference in
//  appium-ios-device's `lib/instrument/index.js` (Apache-2.0 -- read for the channel-open/
//  request-reply protocol, rewritten from scratch in Swift here).
//
//  Channel addressing: channel 0 is the always-open "root" channel. To open a named service
//  channel, the client picks an unused positive `Int32` code and calls
//  `_requestChannelWithCode:identifier:` on the root channel. The device replies to further calls
//  on that channel using the client's code, but sends *unsolicited* notifications back on the
//  two's-complement negation of that code (e.g. if the client opened code 1, the device's
//  `_XCT_...` callbacks arrive tagged with channelCode -1).

import Foundation

actor DTXConnection {

    enum ConnectionError: Swift.Error {
        case closed
        case replyTimeout
        case unexpectedEmptyReply
    }

    private let transport: any DTXByteTransport
    /// Serializes every send/receive on **every** `DTXConnection`'s underlying
    /// `idevice_connection_t`, process-wide -- not just within a single connection.
    ///
    /// Confirmed against real hardware (an iOS 16.7 iPhone) that per-connection locking alone is
    /// necessary but not sufficient. Necessary: without any lock, a connection's background read
    /// loop racing its own in-flight `call()`'s send reliably broke the SSL session
    /// (`IDEVICE_E_SSL_ERROR`, since `idevice_connection_send`/`_receive` call OpenSSL's
    /// `SSL_write`/`SSL_read` directly on a shared `SSL*` with no internal locking -- see
    /// `libimobiledevice/src/idevice.c`). Not sufficient: `TestManagerdSession` opens three
    /// `DTXConnection`s whose read threads all run concurrently for the session's whole lifetime;
    /// with only a per-connection lock, runs got progressively further (past the
    /// `InstallationProxyClient.lookup` crash and the `close()`/receive race, both fixed
    /// separately) but then failed non-deterministically at *different* handshake steps each
    /// time with a clean `ConnectionError.closed` (an unexpected EOF on whichever connection was
    /// waiting for a reply) -- no crash, just cross-connection corruption/interference at the
    /// shared native layer underneath (`libusbmuxd`'s client-side multiplexing is the most likely
    /// candidate, per its non-reentrant-looking C API).
    ///
    /// A `static let ioLock = NSLock()` version of this was tried first and reverted: `NSLock`
    /// gives no fairness guarantee, and with three read threads perpetually re-acquiring it in a
    /// tight poll loop, a `send()` arriving on a fourth thread was starved for minutes (confirmed
    /// against real hardware as a genuine hang, not just added latency). A serial
    /// `DispatchQueue` fixes that: GCD guarantees FIFO execution order for work submitted to a
    /// serial queue, so a `send()` can only ever wait behind operations already queued *before*
    /// it, never behind ones that arrive after -- bounding worst-case wait to (queue depth at
    /// submission time) x `readPollTimeout`, not indefinite.
    private static let legacyIOQueue = DispatchQueue(label: "xtool.dtx.io.legacy")
    /// The classic transport's shared-native-state risk (documented above) doesn't apply to the
    /// iOS 17.4+ tunnel transport (`TunnelDTXTransport`/`PosixTCPSocket`): each connection owns an
    /// independent POSIX file descriptor, which the kernel already serializes safely per-fd on its
    /// own -- there's no shared `SSL*`/`libusbmuxd` state to protect. Forcing tunnel connections
    /// through the same global queue as the legacy ones only adds contention with no safety
    /// benefit, and was confirmed as the source of a real, reproducible failure on real hardware
    /// (iPhone 17 Pro, this session): `TestManagerdSession` runs three DTX connections
    /// concurrently, and during the traffic burst right as the runner launches, one of them could
    /// be starved behind the other two's 200ms poll cycles for long enough that testmanagerd gave
    /// up waiting for its reply and closed the socket from its side (`DTXSocketTransport ...
    /// disconnected` in the device's own log, with no error at all on this end -- the read loop
    /// was still faithfully retrying its timed-out poll, just never getting a turn). Each tunnel
    /// connection gets its own private queue instead; only the legacy transport still shares one.
    /// `nonisolated`: read from `receiveChunk`/`send`/`close`, which run off the actor (the
    /// dedicated read `Thread` and callers awaiting `call()`) -- safe without `await` since it
    /// only reads immutable `let`s (`transport`, `privateIOQueue`).
    private nonisolated var ioQueue: DispatchQueue {
        transport is DTXTransport ? Self.legacyIOQueue : privateIOQueue
    }
    private let privateIOQueue = DispatchQueue(label: "xtool.dtx.io.tunnel")
    private static let readPollTimeout: TimeInterval = 0.2

    /// Guarded by `ioQueue`, not actor isolation -- read from the dedicated read `Thread`
    /// (see `start()`), which cannot `await` its way onto the actor without breaking the "never
    /// block the cooperative thread pool" property this whole design exists for (see `start()`'s
    /// doc comment).
    private nonisolated(unsafe) var stopRequested = false

    private var nextIdentifier: UInt32 = 1
    private var nextClientChannelCode: Int32 = 1
    private var openChannels: [String: Int32] = [:]
    /// Channels the *device* has requested (via its own unsolicited `_requestChannelWithCode:
    /// identifier:` call on the root channel), keyed by channel name, holding the code the device
    /// chose. See `waitForDeviceChannel`'s doc comment for why this exists.
    private var deviceRequestedChannels: [String: Int32] = [:]

    private var pendingReplies: [UInt32: CheckedContinuation<DTXMessage, Swift.Error>] = [:]
    private var selectorHandlers: [String: [@Sendable (DTXMessage) -> Void]] = [:]
    private var unhandledHandler: (@Sendable (DTXMessage) -> Void)?
    /// Selectors that must reply with an actual payload instead of the default empty ack.
    /// Confirmed necessary against go-ios's `proxydispatcher.go`: `_XCT_
    /// testRunnerReadyWithCapabilities:` specifically requires the reply payload to *be* the
    /// archived `XCTestConfiguration`, or `XCTTargetBootstrap` on the device never observes the
    /// test daemon as ready and the run hangs forever waiting on a notification that never comes.
    private var selectorReplyHandlers: [String: @Sendable (DTXMessage) -> NSKeyedValue] = [:]

    private var started = false
    private var closed = false

    init(transport: any DTXByteTransport) {
        self.transport = transport
    }

    /// Starts the background read loop. Must be called once before any `callChannel`/`makeChannel`.
    ///
    /// Runs on a dedicated `Thread`, **not** `Task.detached`/`Task { ... }`. Confirmed against
    /// real hardware that this matters: Swift's concurrency runtime services `Task.detached` work
    /// from a small, fixed-size cooperative thread pool, and this loop makes a genuinely blocking
    /// synchronous C call (`idevice_connection_receive_timeout`) on every iteration for as long as
    /// the connection is open. Parking a `Task.detached` on a blocking call like that starves the
    /// pool of a thread indefinitely; with 2-3 such connections open at once (this session opens
    /// three), the pool was exhausted and unrelated async work elsewhere in the process --
    /// including this actor's own `call()` continuations -- stopped being scheduled at all,
    /// hanging the whole process. A plain `Thread` isn't drawn from that pool, so it can't starve it.
    func start() {
        guard !started else { return }
        started = true
        let thread = Thread { [transport, weak self] in
            self?.readLoop(transport: transport)
        }
        thread.name = "xtool.dtx.read"
        thread.start()
    }

    func close() {
        guard !closed else { return }
        closed = true
        // `transport.close()` must happen inside the same `ioQueue.sync` block as setting
        // `stopRequested`, not after: the read thread's `receiveChunk` runs its blocking
        // `transport.receive` call inside `ioQueue.sync` too (up to `readPollTimeout`), so
        // closing the transport outside the queue let it race an in-flight receive on the same
        // connection -- confirmed against real hardware as a reproducible use-after-free
        // (SIGSEGV inside `SSL_read`, triggered by `TestManagerdSession.stop()` calling `close()`
        // on all three connections while their read threads were still mid-receive). Doing both
        // inside one `sync` block means `close()` waits for any in-flight receive to finish
        // (bounded by `readPollTimeout`) before tearing down the transport, and the read thread's
        // next `shouldStop()`/`receiveChunk` call is guaranteed to happen after the transport is
        // closed, not concurrently with it.
        ioQueue.sync {
            stopRequested = true
            transport.close()
        }
        for continuation in pendingReplies.values {
            continuation.resume(throwing: ConnectionError.closed)
        }
        pendingReplies.removeAll()
    }

    // MARK: - Handler registration

    /// Registers a handler for unsolicited device-initiated calls to `selector` (e.g.
    /// `_XCT_testCaseDidFinishForTestClass:method:withStatus:duration:`), regardless of which
    /// channel they arrive on.
    func onSelector(_ selector: String, handler: @escaping @Sendable (DTXMessage) -> Void) {
        selectorHandlers[selector, default: []].append(handler)
    }

    func onUnhandled(_ handler: @escaping @Sendable (DTXMessage) -> Void) {
        unhandledHandler = handler
    }

    /// Registers a handler for an unsolicited device-initiated call to `selector` whose reply
    /// must carry `handler`'s returned payload, instead of the default empty ack `handle()` sends
    /// for every other message. See `selectorReplyHandlers`'s doc comment for why this exists.
    func onSelectorWithReply(_ selector: String, handler: @escaping @Sendable (DTXMessage) -> NSKeyedValue) {
        selectorReplyHandlers[selector] = handler
    }

    // MARK: - Channels

    /// Opens (or returns the already-open) client-side channel code for `channelName`.
    @discardableResult
    func makeChannel(_ channelName: String) async throws -> Int32 {
        if let existing = openChannels[channelName] {
            return existing
        }
        let code = nextClientChannelCode
        nextClientChannelCode += 1
        var aux = DTXAuxiliaryBuffer()
        aux.append(.int32(code))
        aux.append(.object(.string(channelName)))
        _ = try await call(
            channelCode: 0,
            selector: "_requestChannelWithCode:identifier:",
            auxiliary: aux,
            expectsReply: true
        )
        openChannels[channelName] = code
        return code
    }

    /// Waits for the *device* to open **any** channel via its own unsolicited
    /// `_requestChannelWithCode:identifier:` call -- used purely as a readiness signal, not to
    /// address further calls to that specific channel (`_IDE_startExecutingTestPlanWithProtocolVersion:`
    /// still goes out on the fixed "magic channel", `Self.magicChannel` in `TestManagerdSession`,
    /// same as before -- see below for why that channel code specifically is still correct).
    ///
    /// Confirmed against real hardware (iOS 16.7) that sending
    /// `_IDE_startExecutingTestPlanWithProtocolVersion:` right after `_IDE_
    /// authorizeTestSessionWithProcessID:` succeeds, with nothing else awaited first, reliably
    /// left the on-device test runner never progressing past its own initial bootstrap --
    /// testmanagerd reported the exec-test-plan session as merely "waiting to pair" indefinitely,
    /// no crash, no error, no further DTX traffic at all. go-ios's `xcuitestrunner_12.go`/
    /// `xcuitestrunner.go` (read for control flow only, not copied -- see this file's header
    /// comment) resolve this by waiting for the device's own `_requestChannelWithCode:identifier:`
    /// call to arrive (its own comment: "for some reason it requests the TestDriver proxy channel
    /// with code 1 but sends messages on -1" -- i.e. even go-ios still hardcodes channel -1 for
    /// the actual send; the device's channel-open request is used purely as a synchronization
    /// gate, not to learn which channel code to use) before sending on the magic channel.
    func waitForAnyDeviceChannelRequest(timeout: TimeInterval = 30) async throws {
        // Polls rather than using a continuation: `handle()` (which populates
        // `deviceRequestedChannels`) runs on this same actor, so each `Task.sleep` below
        // suspends this method and yields the actor's executor to it between checks -- simpler
        // and leak-free compared to managing continuations that might never get resumed if the
        // device never opens any channel at all (a real, possible outcome this function must
        // handle, not just a slow-path edge case).
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if !deviceRequestedChannels.isEmpty {
                return
            }
            guard Date() < deadline else { throw ConnectionError.replyTimeout }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The code the device chose for whichever channel it requested via its own unsolicited
    /// `_requestChannelWithCode:identifier:` (see `waitForAnyDeviceChannelRequest`'s doc comment).
    /// `TestManagerdSession` uses this, when available, to address
    /// `_IDE_startExecutingTestPlanWithProtocolVersion:` to the device's *actual* negotiated
    /// channel instead of a hardcoded magic constant -- go-ios hardcodes -1 regardless (per its
    /// own source comment, quoted in `waitForAnyDeviceChannelRequest`'s doc comment), but
    /// pymobiledevice3's actively-maintained DTX implementation instead waits for and addresses
    /// this exact negotiated channel (`wait_for_proxied_service(..., remote=True)` in its
    /// `dtx/connection.py`) -- a real, previously-untried discrepancy between the two references,
    /// worth trying given the hardcoded-`-1` approach was already confirmed not to work end-to-end
    /// on two separate real devices.
    func anyDeviceRequestedChannelCode() -> Int32? {
        deviceRequestedChannels.values.first
    }

    /// Opens `channelName` if needed, then invokes `selector` on it and awaits the reply.
    @discardableResult
    func callChannel(
        _ channelName: String,
        selector: String,
        auxiliary: DTXAuxiliaryBuffer = DTXAuxiliaryBuffer(),
        expectsReply: Bool = true
    ) async throws -> DTXMessage {
        let channelCode = try await makeChannel(channelName)
        return try await call(channelCode: channelCode, selector: selector, auxiliary: auxiliary, expectsReply: expectsReply)
    }

    /// Low-level send-and-wait, addressed directly by channel code (use `callChannel` for named
    /// service channels; this exists for the root channel (code 0) and the "magic" broadcast
    /// channel testmanagerd's `_IDE_startExecutingTestPlanWithProtocolVersion:` is sent on).
    @discardableResult
    func call(
        channelCode: Int32,
        selector: String,
        auxiliary: DTXAuxiliaryBuffer = DTXAuxiliaryBuffer(),
        expectsReply: Bool = true
    ) async throws -> DTXMessage {
        guard !closed else { throw ConnectionError.closed }
        let identifier = nextIdentifier
        nextIdentifier += 1

        var message = DTXMessage(
            identifier: identifier,
            channelCode: channelCode,
            expectsReply: expectsReply,
            flags: .send,
            payload: .string(selector)
        )
        message.auxiliary = auxiliary

        if !expectsReply {
            try send(message)
            // synthesize an empty ack so callers can uniformly `await` this method
            return DTXMessage(identifier: identifier, channelCode: channelCode)
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingReplies[identifier] = continuation
            do {
                try send(message)
            } catch {
                pendingReplies[identifier] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Sends an empty acknowledgment reply, as required whenever an incoming message has
    /// `expectsReply` set.
    private func sendAck(for message: DTXMessage) {
        let ack = DTXMessage(
            identifier: message.identifier,
            channelCode: message.channelCode,
            conversationIndex: message.conversationIndex + 1,
            flags: .reply
        )
        try? send(ack)
    }

    /// Sends a reply carrying `payload`, for the (rare) incoming calls that require a real
    /// return value instead of an empty ack -- confirmed against go-ios's `proxydispatcher.go`
    /// that `_XCT_testRunnerReadyWithCapabilities:` is exactly this case: the runner's reply
    /// needs to *be* the archived `XCTestConfiguration`, not an empty ack, or it never proceeds
    /// past waiting for one (see `onSelectorWithReply`'s doc comment for the full story).
    private func sendReply(_ payload: NSKeyedValue, for message: DTXMessage) {
        let reply = DTXMessage(
            identifier: message.identifier,
            channelCode: message.channelCode,
            conversationIndex: message.conversationIndex + 1,
            flags: .reply,
            payload: payload
        )
        try? send(reply)
    }

    private nonisolated func send(_ message: DTXMessage) throws {
        if ProcessInfo.processInfo.environment["XTOOL_DTX_TRACE"] != nil {
            FileHandle.standardError.write(Data(
                "[dtx-trace-out] channel=\(message.channelCode) conv=\(message.conversationIndex) expectsReply=\(message.expectsReply) payload=\(String(describing: message.payload))\n".utf8
            ))
        }
        let data = message.encoded()
        try ioQueue.sync {
            _ = try transport.send(data)
        }
    }

    // MARK: - Read loop

    private nonisolated func shouldStop() -> Bool {
        ioQueue.sync { stopRequested }
    }

    /// Runs entirely on the dedicated `Thread` `start()` spins up -- never on the actor's
    /// executor or the cooperative thread pool (see `start()`'s doc comment for why that matters).
    /// Each fully-reassembled message is handed back to the actor via a plain (non-detached)
    /// `Task { await self.handle(...) }` hop, which is cheap and doesn't itself block anything.
    private nonisolated func readLoop(transport: any DTXByteTransport) {
        var assembly: [Int32: (header: DTXMessage.ParsedHeader, body: Data)] = [:]
        while !shouldStop() {
            do {
                let headerBytes = try readExact(transport, DTXMessage.headerLength)
                let header = try DTXMessage.parseHeader(headerBytes)
                let payload = try readExact(transport, Int(header.payloadLength))

                if header.fragmentCount > 1 {
                    if header.fragmentId == 0 {
                        // fragment 0 of a multi-fragment message carries no body of its own in
                        // some DTX producers; still, treat any payload it does carry as the start
                        // of the accumulated body for consistency.
                        assembly[header.channelCode] = (header, payload)
                        continue
                    }
                    assembly[header.channelCode, default: (header, Data())].body += payload
                    guard header.fragmentId == header.fragmentCount - 1 else { continue }
                    guard let complete = assembly.removeValue(forKey: header.channelCode) else { continue }
                    let message = try DTXMessage.parseBody(complete.header, body: complete.body)
                    Task { await self.handle(message) }
                } else {
                    let message = try DTXMessage.parseBody(header, body: payload)
                    Task { await self.handle(message) }
                }
            } catch {
                Task { await self.handleReadLoopError(error) }
                return
            }
        }
    }

    private nonisolated func readExact(_ transport: any DTXByteTransport, _ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(capacity: count)
        while data.count < count {
            data += try receiveChunk(transport, maxLength: count - data.count)
        }
        return data
    }

    /// A single bounded-time read attempt, retrying on timeout. Uses a short timeout (rather
    /// than blocking indefinitely) specifically so `ioQueue` is freed up often enough for
    /// concurrent sends/receives on other connections to get a turn -- see `ioQueue`'s doc comment.
    private nonisolated func receiveChunk(_ transport: any DTXByteTransport, maxLength: Int) throws -> Data {
        while true {
            guard !shouldStop() else { throw ConnectionError.closed }
            let result = ioQueue.sync {
                Result { try transport.receive(maxLength: maxLength, timeout: Self.readPollTimeout) }
            }
            do {
                let chunk = try result.get()
                guard !chunk.isEmpty else { throw ConnectionError.closed }
                return chunk
            } catch {
                guard transport.isTimeout(error) else { throw error }
                continue
            }
        }
    }

    private func handleReadLoopError(_ error: Swift.Error) {
        guard !closed else { return }
        closed = true
        for continuation in pendingReplies.values {
            continuation.resume(throwing: error)
        }
        pendingReplies.removeAll()
    }

    private func handle(_ message: DTXMessage) {
        if ProcessInfo.processInfo.environment["XTOOL_DTX_TRACE"] != nil {
            FileHandle.standardError.write(Data(
                "[dtx-trace] channel=\(message.channelCode) conv=\(message.conversationIndex) expectsReply=\(message.expectsReply) payload=\(String(describing: message.payload)) aux=\(message.auxiliary.values)\n".utf8
            ))
        }
        // a reply to one of our own requests: conversationIndex advances from 0 (our request) to
        // 1 (the device's single reply).
        if message.conversationIndex >= 1, let continuation = pendingReplies.removeValue(forKey: message.identifier) {
            continuation.resume(returning: message)
            return
        }

        // the device opening its own channel on us -- the reverse of `makeChannel`. Same call the
        // client uses to open a channel on the device (`_requestChannelWithCode:identifier:`,
        // aux = [rawCode, boxedName]), just device-initiated. See `waitForDeviceChannel`'s doc
        // comment for why this needs recognizing structurally, not just surfaced via `onUnhandled`.
        if message.channelCode == 0, case .string("_requestChannelWithCode:identifier:")? = message.payload,
           case .int32(let code)? = message.auxiliary.values.first,
           case .object(.string(let name))? = message.auxiliary.values.dropFirst().first {
            deviceRequestedChannels[name] = code
        }

        // a selector whose reply must carry an actual payload (see `selectorReplyHandlers`'s doc
        // comment) -- handled and replied to here, bypassing the generic dispatch/ack path below
        // entirely, since the reply itself IS the response, not a followup broadcast.
        if case .string(let selector)? = message.payload, let replyHandler = selectorReplyHandlers[selector] {
            let payload = replyHandler(message)
            if message.expectsReply {
                sendReply(payload, for: message)
            }
            return
        }

        // an unsolicited call from the device, matched by selector regardless of channel.
        var dispatched = false
        if case .string(let selector)? = message.payload, let handlers = selectorHandlers[selector] {
            for handler in handlers { handler(message) }
            dispatched = true
        }
        if !dispatched {
            unhandledHandler?(message)
        }

        if message.expectsReply {
            sendAck(for: message)
        }
    }
}
