//
//  RemoteXPCConnection.swift
//  XKit
//
//  Wraps `MinimalHTTP2Connection` + `RemoteXPCCodec` into the actual RemoteXPC connection
//  protocol iOS 17+ uses for RSD lookups and the tunnel pairing/control channel: a 3-message
//  handshake once the underlying HTTP/2 connection is up, then plain `send`/`receive` of encoded
//  dictionaries on the client-server (host->device) and server-client (device->host) streams.
//  Structured after the documented, working reference in go-ios's `ios/connect.go`
//  (`initializeXpcConnection`/`CreateXpcConnection`) and `ios/xpc/xpc.go` (MIT -- read for the
//  handshake message sequence, rewritten from scratch in Swift here; same clean-room approach as
//  the rest of this directory).
//

import Foundation

public final class RemoteXPCConnection: @unchecked Sendable {
    private let http2: MinimalHTTP2Connection
    private var nextMsgId: UInt64 = 1

    public init(stream: ByteStream) throws {
        self.http2 = try MinimalHTTP2Connection(stream: stream)
        try Self.performHandshake(http2)
    }

    /// The exact 3-message exchange go-ios's `initializeXpcConnection` performs. The specific
    /// flag values (`0x201` on the third message) aren't independently meaningful here -- they're
    /// just the bytes real `remoted` expects to see before it starts accepting normal messages.
    private static func performHandshake(_ http2: MinimalHTTP2Connection) throws {
        try writeMessage(http2, on: .clientServer, RemoteXPCMessage(flags: RemoteXPCFlag.alwaysSet, body: [:], id: 0))
        _ = try readMessage(http2, on: .clientServer)

        try writeMessage(
            http2, on: .serverClient,
            RemoteXPCMessage(flags: RemoteXPCFlag.initHandshake | RemoteXPCFlag.alwaysSet, body: nil, id: 0)
        )
        _ = try readMessage(http2, on: .serverClient)

        try writeMessage(http2, on: .clientServer, RemoteXPCMessage(flags: 0x201, body: nil, id: 0))
        _ = try readMessage(http2, on: .clientServer)
    }

    /// Sends `data` as a RemoteXPC message on the client-server (host->device) stream.
    func send(_ data: [String: RemoteXPCValue]?, extraFlags: UInt32 = 0) throws {
        var flags = RemoteXPCFlag.alwaysSet | extraFlags
        if data != nil { flags |= RemoteXPCFlag.data }
        let message = RemoteXPCMessage(flags: flags, body: data, id: nextMsgId)
        if ProcessInfo.processInfo.environment["XTOOL_XPC_TRACE"] != nil {
            FileHandle.standardError.write(Data("[xpc-trace-out] flags=\(flags) id=\(nextMsgId) body=\(String(describing: data))\n".utf8))
        }
        try Self.writeMessage(http2, on: .clientServer, message)
    }

    /// Blocks until a full message has been received on the client-server stream (used by RSD's
    /// handshake, which -- despite the naming -- is a message *from* the device delivered on the
    /// stream this host reads inbound traffic from; see `MinimalHTTP2Connection`'s doc comment for
    /// why both directions share stream id 1 in this specific usage. Matches go-ios's
    /// `ReceiveOnClientServerStream`, which reads the same stream regardless of direction).
    func receiveOnClientServerStream() throws -> [String: RemoteXPCValue]? {
        let body = try Self.readMessage(http2, on: .clientServer).body
        if ProcessInfo.processInfo.environment["XTOOL_XPC_TRACE"] != nil {
            FileHandle.standardError.write(Data("[xpc-trace-in] body=\(String(describing: body))\n".utf8))
        }
        return body
    }

    private static func writeMessage(_ http2: MinimalHTTP2Connection, on streamID: MinimalHTTP2Connection.StreamID, _ message: RemoteXPCMessage) throws {
        let encoded = RemoteXPCCodec.encode(message)
        switch streamID {
        case .clientServer: try http2.writeClientServerStream(encoded)
        case .serverClient: try http2.writeServerClientStream(encoded)
        }
    }

    private static func readMessage(_ http2: MinimalHTTP2Connection, on streamID: MinimalHTTP2Connection.StreamID) throws -> RemoteXPCMessage {
        let header: Data
        switch streamID {
        case .clientServer: header = try http2.readClientServerStream(exactly: RemoteXPCCodec.wrapperHeaderLength)
        case .serverClient: header = try http2.readServerClientStream(exactly: RemoteXPCCodec.wrapperHeaderLength)
        }
        let bodyLength = try Int(RemoteXPCCodec.bodyLength(fromHeader: header))
        guard bodyLength > 0 else {
            return try RemoteXPCCodec.decode(header)
        }
        let body: Data
        switch streamID {
        case .clientServer: body = try http2.readClientServerStream(exactly: bodyLength)
        case .serverClient: body = try http2.readServerClientStream(exactly: bodyLength)
        }
        return try RemoteXPCCodec.decode(header + body)
    }
}
