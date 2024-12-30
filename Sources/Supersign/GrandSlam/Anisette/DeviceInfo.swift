//
//  DeviceInfo.swift
//  Supersign
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
    public static let xcodeVersion = "14.2 (14C18)"

    public struct ClientInfo: Codable {
        public static let macOSVersion = "10.14.6"
        public static let macOSBuild = "18G103"

        public static let authKitVersion = "1"
        public static let akdVersion = "1.0"
        public static let cfNetworkVersion = "978.0.7"
        public static let darwinVersion = "18.7.0"

        public let modelID: String // e.g. MacBookPro11,5

        // TODO: Do we need to replace com.apple.akd with com.apple.dt.Xcode? See AltStore
        var clientString: String {
            """
            <\(modelID)> <Mac OS X;\(Self.macOSVersion);\(Self.macOSBuild)> \
            <com.apple.AuthKit/\(Self.authKitVersion) (com.apple.akd/\(Self.akdVersion))>
            """
        }

        var userAgent: String {
            "akd/\(Self.akdVersion) CFNetwork/\(Self.cfNetworkVersion) Darwin/\(Self.darwinVersion)"
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
    public static let liveValue = DeviceInfoProvider { try current.get() }
}

extension DependencyValues {
    public var deviceInfoProvider: DeviceInfoProvider {
        get { self[DeviceInfoProvider.self] }
        set { self[DeviceInfoProvider.self] = newValue }
    }
}
