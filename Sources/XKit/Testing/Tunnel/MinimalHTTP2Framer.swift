//
//  MinimalHTTP2Framer.swift
//  XKit
//
//  iOS 17+'s RemoteXPC services are carried over HTTP/2, but only as a framing/multiplexing
//  layer -- there's no real HTTP semantics (no headers, no methods, no status codes) involved.
//  Two fixed streams are used: id 1 ("client-server") for host-to-device messages, id 3
//  ("server-client") for device-to-host. This is a from-scratch implementation of exactly the
//  subset of HTTP/2 framing that requires -- connection preface, SETTINGS, WINDOW_UPDATE, and
//  DATA frames on those two streams -- structured after the documented, working reference in
//  go-ios's `ios/http/http.go` (MIT -- read for the exact handshake byte sequence, rewritten from
//  scratch in Swift here; same clean-room approach as `DTXMessage.swift`/`RemoteXPCCodec.swift`).
//  A full HTTP/2 client (HPACK, flow control, real header blocks) is unnecessary and not
//  implemented.
//

import Foundation

/// A minimal blocking byte-stream abstraction, implemented by whatever the RemoteXPC connection
/// actually rides on (a raw TCP socket to the device's RSD port over the TUN interface -- see
/// `TUNDevice.swift`).
public protocol ByteStream: Sendable {
    func send(_ data: Data) throws
    /// Blocking read of at most `maxLength` bytes. Returns an empty `Data` only at EOF.
    func receive(maxLength: Int) throws -> Data
}

enum ByteStreamError: Swift.Error {
    case unexpectedEOF
}

extension ByteStream {
    /// Blocks until exactly `count` bytes have been read.
    func readExact(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let chunk = try receive(maxLength: count - result.count)
            guard !chunk.isEmpty else { throw ByteStreamError.unexpectedEOF }
            result += chunk
        }
        return result
    }
}

enum HTTP2FrameType: UInt8 {
    case data = 0x0
    case headers = 0x1
    case rstStream = 0x3
    case settings = 0x4
    case goAway = 0x7
    case windowUpdate = 0x8
}

struct HTTP2Frame {
    var type: HTTP2FrameType
    var flags: UInt8
    var streamId: UInt32
    var payload: Data
}

enum HTTP2Error: Swift.Error {
    case unknownFrameType(UInt8)
    case unexpectedFrame(HTTP2FrameType)
    case goAway
    case rstStream
    case unknownStream(UInt32)
}

private let http2ClientPreface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
private let settingsMaxConcurrentStreams: UInt16 = 0x3
private let settingsInitialWindowSize: UInt16 = 0x4
private let settingsAckFlag: UInt8 = 0x1
private let headersEndHeadersFlag: UInt8 = 0x4

enum HTTP2FrameIO {
    static func writeFrame(
        _ stream: ByteStream, type: HTTP2FrameType, flags: UInt8 = 0, streamId: UInt32, payload: Data = Data()
    ) throws {
        var out = Data()
        let length = payload.count
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(type.rawValue)
        out.append(flags)
        let sid = streamId & 0x7FFF_FFFF
        out.append(UInt8((sid >> 24) & 0xFF))
        out.append(UInt8((sid >> 16) & 0xFF))
        out.append(UInt8((sid >> 8) & 0xFF))
        out.append(UInt8(sid & 0xFF))
        out += payload
        try stream.send(out)
    }

    static func readFrame(_ stream: ByteStream) throws -> HTTP2Frame {
        let header = Array(try stream.readExact(9))
        let length = (Int(header[0]) << 16) | (Int(header[1]) << 8) | Int(header[2])
        guard let type = HTTP2FrameType(rawValue: header[3]) else {
            throw HTTP2Error.unknownFrameType(header[3])
        }
        let flags = header[4]
        let streamId = (UInt32(header[5]) << 24 | UInt32(header[6]) << 16
            | UInt32(header[7]) << 8 | UInt32(header[8])) & 0x7FFF_FFFF
        let payload = length > 0 ? try stream.readExact(length) : Data()
        return HTTP2Frame(type: type, flags: flags, streamId: streamId, payload: payload)
    }
}

/// A connection carrying exactly two logical byte-streams (client-server = stream 1,
/// server-client = stream 3) multiplexed over minimal HTTP/2 DATA framing. Not an actor: every
/// call blocks synchronously on the underlying `ByteStream`, and (matching go-ios's usage of this
/// layer) nothing here needs concurrent access from multiple tasks -- callers that need
/// background reads build that on top, same as `DTXConnection` builds its read loop on top of the
/// synchronous `DTXTransport`.
final class MinimalHTTP2Connection: @unchecked Sendable {
    enum StreamID: UInt32 {
        case clientServer = 1
        case serverClient = 3
    }

    private let stream: ByteStream
    private var clientServerBuffer = Data()
    private var serverClientBuffer = Data()
    private var clientServerHeadersSent = false
    private var serverClientHeadersSent = false

    /// Performs the connection preface + SETTINGS/WINDOW_UPDATE exchange. Mirrors go-ios's
    /// `NewHttpConnection` exactly (including the specific setting values and the single
    /// expected-SETTINGS-frame read), since these are just the bytes real `remoted` expects, not
    /// values with independent meaning to this implementation.
    init(stream: ByteStream) throws {
        self.stream = stream

        try stream.send(http2ClientPreface)

        var settingsPayload = Data()
        appendSetting(&settingsPayload, id: settingsMaxConcurrentStreams, value: 100)
        appendSetting(&settingsPayload, id: settingsInitialWindowSize, value: 1_048_576)
        try HTTP2FrameIO.writeFrame(stream, type: .settings, streamId: 0, payload: settingsPayload)

        var windowUpdatePayload = Data()
        appendBE32(&windowUpdatePayload, 983_041)
        try HTTP2FrameIO.writeFrame(stream, type: .windowUpdate, streamId: 0, payload: windowUpdatePayload)

        let frame = try HTTP2FrameIO.readFrame(stream)
        if frame.type == .settings, frame.flags & settingsAckFlag == 0 {
            try HTTP2FrameIO.writeFrame(stream, type: .settings, flags: settingsAckFlag, streamId: 0)
        }
    }

    func writeClientServerStream(_ data: Data) throws {
        try write(data, stream: .clientServer, headersSent: &clientServerHeadersSent)
    }

    func writeServerClientStream(_ data: Data) throws {
        try write(data, stream: .serverClient, headersSent: &serverClientHeadersSent)
    }

    private func write(_ data: Data, stream streamID: StreamID, headersSent: inout Bool) throws {
        if !headersSent {
            try HTTP2FrameIO.writeFrame(stream, type: .headers, flags: headersEndHeadersFlag, streamId: streamID.rawValue)
            headersSent = true
        }
        try HTTP2FrameIO.writeFrame(stream, type: .data, streamId: streamID.rawValue, payload: data)
    }

    func readClientServerStream(exactly count: Int) throws -> Data {
        try read(exactly: count, from: .clientServer)
    }

    func readServerClientStream(exactly count: Int) throws -> Data {
        try read(exactly: count, from: .serverClient)
    }

    /// Deliberately doesn't take the buffer as an `inout` parameter: an `inout` access to
    /// `clientServerBuffer`/`serverClientBuffer` held for this whole function's duration would
    /// overlap with `readDataFrame()`'s own direct mutation of that same property (it appends to
    /// `self.clientServerBuffer`/`self.serverClientBuffer` while called from here) -- a genuine
    /// Swift exclusivity violation, confirmed via a real crash ("Fatal access conflict detected")
    /// during real-device testing. Re-reading `self.<buffer>.count`/re-slicing on each iteration
    /// instead keeps every access short-lived and non-overlapping.
    private func read(exactly count: Int, from streamID: StreamID) throws -> Data {
        while bufferedCount(for: streamID) < count {
            try readDataFrame()
        }
        switch streamID {
        case .clientServer:
            let result = clientServerBuffer.prefix(count)
            clientServerBuffer.removeFirst(count)
            return Data(result)
        case .serverClient:
            let result = serverClientBuffer.prefix(count)
            serverClientBuffer.removeFirst(count)
            return Data(result)
        }
    }

    private func bufferedCount(for streamID: StreamID) -> Int {
        switch streamID {
        case .clientServer: return clientServerBuffer.count
        case .serverClient: return serverClientBuffer.count
        }
    }

    /// Reads and dispatches frames until a DATA frame has been appended to the relevant buffer.
    /// SETTINGS frames are ACKed inline (the device sends periodic heartbeat-adjacent SETTINGS
    /// updates); GOAWAY/RST_STREAM are treated as fatal, matching go-ios.
    private func readDataFrame() throws {
        while true {
            let frame = try HTTP2FrameIO.readFrame(stream)
            switch frame.type {
            case .data:
                switch frame.streamId {
                case StreamID.clientServer.rawValue: clientServerBuffer += frame.payload
                case StreamID.serverClient.rawValue: serverClientBuffer += frame.payload
                default: throw HTTP2Error.unknownStream(frame.streamId)
                }
                return
            case .goAway:
                throw HTTP2Error.goAway
            case .settings:
                if frame.flags & settingsAckFlag == 0 {
                    try HTTP2FrameIO.writeFrame(stream, type: .settings, flags: settingsAckFlag, streamId: 0)
                }
            case .rstStream:
                throw HTTP2Error.rstStream
            case .headers, .windowUpdate:
                break
            }
        }
    }
}

private func appendSetting(_ data: inout Data, id: UInt16, value: UInt32) {
    data.append(UInt8((id >> 8) & 0xFF))
    data.append(UInt8(id & 0xFF))
    appendBE32(&data, value)
}

private func appendBE32(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}
