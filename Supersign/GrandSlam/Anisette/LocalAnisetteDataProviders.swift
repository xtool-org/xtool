//
//  LocalAnisetteDataProviders.swift
//  Supersign
//
//  Created by Kabir Oberai on 29/06/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import Foundation

/// Creates a socket connected to `ip` on `port`.
///
/// - Returns: A connected socket file descriptor, or `nil` if
/// the connection failed. The caller is responsible for closing
/// the returned file descriptor.
private func connect(toIP ip: String, port: UInt16) -> Int32? {
    var addr = sockaddr_in()
    addr.sin_family = .init(AF_INET)
    addr.sin_port = CFSwapInt16HostToBig(port)
    addr.sin_addr.s_addr = inet_addr(ip)

    // we can't do this inside withUnsafePointer due to memory exclusivity rules
    let addrSize = MemoryLayout.size(ofValue: addr)

    let socketFd = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFd != -1 else { return nil }
    guard withUnsafePointer(to: &addr, {
        connect(
            socketFd,
            UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self),
            .init(addrSize)
        )
    }) == 0 else { return nil }

    return socketFd
}

public class NetcatAnisetteDataProvider: AnisetteDataProvider {

    private struct RawAnisetteData {
        let machineID: String
        let localUserID: String
        let routingInfo: String
        let oneTimePassword: String
    }

    private class ConnectionInfo {
        let socketFd: Int32
        let machineID: String
        let localUserID: String
        let routingInfo: String
        let firstOTP: String

        init(socketFd: Int32, machineID: String, localUserID: String, routingInfo: String, firstOTP: String) {
            self.socketFd = socketFd
            self.machineID = machineID
            self.localUserID = localUserID
            self.routingInfo = routingInfo
            self.firstOTP = firstOTP
        }

        deinit { close(socketFd) }
    }

    public enum Error: Swift.Error {
        /// The user is probably not running anisettehelperd on the host machine
        case helperUnreachable
        case invalidAnisetteData
        case networkError(errno: Int32)
    }

    public let ip: String
    public let port: UInt16
    public let deviceInfo: DeviceInfo
    private var _connectionInfo: ConnectionInfo?
    private var hasUsedFirstOTP = false

    public init(ip: String, port: UInt16, deviceInfo: DeviceInfo) {
        self.ip = ip
        self.port = port
        self.deviceInfo = deviceInfo
    }

    public convenience init(localPort port: UInt16, deviceInfo: DeviceInfo) {
        self.init(ip: "0.0.0.0", port: port, deviceInfo: deviceInfo)
    }

    private func readAll(fromSocket sock: Int32) throws -> Data {
        let capacity = 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buf.deallocate() }
        var data = Data()
        while true {
            let count = recv(sock, buf, capacity, 0)
            guard count != -1 else {
                throw Error.networkError(errno: errno)
            }
            data.append(buf, count: count)
            if count < capacity {
                break
            }
        }
        return data
    }

    private func connectionInfo() throws -> ConnectionInfo {
        if let connectionInfo = _connectionInfo { return connectionInfo }

        guard let socketFd = connect(toIP: ip, port: port) else { throw Error.helperUnreachable }

        let id = deviceInfo.deviceID
        write(socketFd, id, strlen(id) + 1) // include null
        let clientInfo = deviceInfo.clientInfo.clientString
        write(socketFd, clientInfo, strlen(clientInfo) + 1)

        let initialData = try readAll(fromSocket: socketFd)
        guard let string = String(data: initialData, encoding: .utf8)
            else { throw Error.invalidAnisetteData }

        let components = string.split(separator: "\r\n")
        guard components.count == 4 else { throw Error.invalidAnisetteData }

        let connectionInfo = ConnectionInfo(
            socketFd: socketFd,
            machineID: String(components[0]),
            localUserID: String(components[1]),
            routingInfo: String(components[2]),
            firstOTP: String(components[3])
        )
        _connectionInfo = connectionInfo
        return connectionInfo
    }

    private func rawAnisetteData() throws -> RawAnisetteData {
        let info = try connectionInfo()
        if !hasUsedFirstOTP {
            return RawAnisetteData(
                machineID: info.machineID,
                localUserID: info.localUserID,
                routingInfo: info.routingInfo,
                oneTimePassword: info.firstOTP
            )
        }

        write(info.socketFd, "a\n", 3)
        let response = try readAll(fromSocket: info.socketFd)
        guard let otp = String(data: response, encoding: .utf8)
            else { throw Error.invalidAnisetteData }
        return RawAnisetteData(
            machineID: info.machineID,
            localUserID: info.localUserID,
            routingInfo: info.routingInfo,
            oneTimePassword: otp
        )
    }

    public func fetchAnisetteData(completion: @escaping (Result<AnisetteData, Swift.Error>) -> Void) {
        let time = Date()

        let raw: RawAnisetteData
        let routingInfo: UInt64
        do {
            raw = try rawAnisetteData()
            guard let rinfo = UInt64(raw.routingInfo)
                else { throw Error.invalidAnisetteData }
            routingInfo = rinfo
        } catch {
            return completion(.failure(error))
        }

        let anisette = AnisetteData(
            clientTime: time,
            routingInfo: routingInfo,
            machineID: raw.machineID,
            localUserID: raw.localUserID,
            oneTimePassword: raw.oneTimePassword
        )

        completion(.success(anisette))
    }

}

/// Provides Anisette Data by making a request to a TCP server
public class TCPAnisetteDataProvider: AnisetteDataProvider {

    public enum Error: Swift.Error {
        /// The user is probably not running anisettehelperd on the host machine
        case helperUnreachable
        case invalidAnisetteData
    }

    public let ip: String
    public let port: UInt16

    public init(ip: String, port: UInt16) {
        self.ip = ip
        self.port = port
    }

    public convenience init(localPort port: UInt16) {
        self.init(ip: "0.0.0.0", port: port)
    }

    private func rawAnisetteData() throws -> Data {
        guard let socketFd = connect(toIP: ip, port: port) else { throw Error.helperUnreachable }

        let capacity = 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buf.deallocate() }
        var data = Data()
        while true {
            let count = recv(socketFd, buf, capacity, 0)
            // swiftlint:disable:next empty_count
            guard count != 0 else { break }
            data.append(buf, count: count)
        }

        return data
    }

    public func fetchAnisetteData(completion: @escaping (Result<AnisetteData, Swift.Error>) -> Void) {
        let time = Date()

        let rawDeserialized: Any
        do {
            let raw = try rawAnisetteData()
            rawDeserialized = try PropertyListSerialization.propertyList(from: raw, format: nil)
        } catch {
            return completion(.failure(error))
        }

        guard let data = rawDeserialized as? [String: Any],
            let rinfoString = data[AnisetteData.routingInfoKey] as? String,
            let rinfo = UInt64(rinfoString),
            let machineID = data[AnisetteData.machineIDKey] as? String,
            let localUserID = data[AnisetteData.localUserIDKey] as? String,
            let oneTimePassword = data[AnisetteData.oneTimePasswordKey] as? String
            else { return completion(.failure(Error.invalidAnisetteData)) }

        completion(.success(AnisetteData(
            clientTime: time,
            routingInfo: rinfo,
            machineID: machineID,
            localUserID: localUserID,
            oneTimePassword: oneTimePassword
        )))
    }

}
