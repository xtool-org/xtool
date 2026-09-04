//
//  DeviceInfo.swift
//  XKit
//
//  Created by Kabir Oberai on 19/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import Dependencies

public struct DeviceInfo: Codable, Sendable {

    /// `X-Xcode-Version`
    static let xcodeVersionKey = "X-Xcode-Version"
    /// Not included in `dictionary`
    public static let xcodeVersion = "26.5 (17F42)"

    public struct ClientInfo: Codable {
        public let modelID: String // e.g. MacBookPro11,5

        var clientString: String {
            """
            <\(modelID)> <macOS;26.6;25G72> <com.apple.AuthKit/1 (com.apple.dt.Xcode/26.0)>
            """
        }

        var userAgent: String {
            "AuthKit/1 (Macintosh; OS X 26.6) (com.apple.dt.Xcode/26.0)"
        }

        public init(modelID: String) {
            self.modelID = modelID
        }
    }

    /// `X-Mme-Device-Id`
    static let deviceIDKey = "X-Mme-Device-Id"
    public let deviceID: String

    /// `X-Apple-I-ROM`
    static let romAddressKey = "X-Apple-I-ROM"
    public let romAddress: String

    /// `X-Apple-I-MLB`
    static let mlbSerialNumberKey = "X-Apple-I-MLB"
    /// main logic board serial number
    public let mlbSerialNumber: String

    /// `X-Apple-I-SRL-NO`
    static let serialNumberKey = "X-Apple-I-SRL-NO"
    public let serialNumber: String

    public let modelID: String

    /// `X-MMe-Client-Info`
    static let clientInfoKey = "X-MMe-Client-Info"
    public var clientInfo: ClientInfo { .init(modelID: modelID) }

    public init(
        deviceID: String,
        romAddress: String,
        mlbSerialNumber: String,
        serialNumber: String,
        modelID: String
    ) {
        self.deviceID = deviceID
        self.romAddress = romAddress
        self.mlbSerialNumber = mlbSerialNumber
        self.serialNumber = serialNumber
        self.modelID = modelID
    }

    var dictionary: [String: String] {
        [
            Self.deviceIDKey: deviceID,
            Self.romAddressKey: romAddress,
            Self.mlbSerialNumberKey: mlbSerialNumber,
            Self.serialNumberKey: serialNumber
        ]
    }

}

extension DeviceInfo {
    public enum FetchError: Error {
        case couldNotFetch
    }

    fileprivate static func fetch() throws -> Self {
        guard let deviceInfo = DeviceInfo.current() else {
            throw FetchError.couldNotFetch
        }
        return deviceInfo
    }
}

public struct DeviceInfoProvider: DependencyKey, Sendable {
    public var fetch: @Sendable () throws -> DeviceInfo

    public init(fetch: @escaping @Sendable () throws -> DeviceInfo) {
        self.fetch = fetch
    }

    private static let current = Result { try DeviceInfo.fetch() }

    public static let testValue = DeviceInfoProvider(fetch: unimplemented())
    public static let liveValue = DeviceInfoProvider { try current.get() }
}

extension DependencyValues {
    public var deviceInfoProvider: DeviceInfoProvider {
        get { self[DeviceInfoProvider.self] }
        set { self[DeviceInfoProvider.self] = newValue }
    }
}
