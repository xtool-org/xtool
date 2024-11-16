//
//  AnisetteData.swift
//  Supersign
//
//  Created by Kabir Oberai on 19/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

public struct AnisetteData {

    private static let dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return dateFormatter
    }()

    /// `X-Apple-I-Locale`
    static let iLocaleKey = "X-Apple-I-Locale"
    /// `X-Apple-Locale`
    static let localeKey = "X-Apple-Locale"
    public let locale: Locale = .current

    /// `X-Apple-I-TimeZone`
    static let timeZoneKey = "X-Apple-I-TimeZone"
    public let timeZone: TimeZone = .current

    /// `X-Apple-I-Client-Time`
    static let clientTimeKey = "X-Apple-I-Client-Time"
    public let clientTime: Date

    /// `X-Apple-I-MD-RINFO`
    static let routingInfoKey = "X-Apple-I-MD-RINFO"
    public let routingInfo: UInt64

    /// `X-Apple-I-MD-M`
    static let machineIDKey = "X-Apple-I-MD-M"
    public let machineID: String

    /// `X-Apple-I-MD-LU`
    static let localUserIDKey = "X-Apple-I-MD-LU"
    public let localUserID: String

    /// `X-Apple-I-MD`
    static let oneTimePasswordKey = "X-Apple-I-MD"
    public let oneTimePassword: String

    static let deviceIDKey = "X-Mme-Device-Id"
    public var deviceID: String?

    var dictionary: [String: String] {
        let localeIdentifier = if let language = locale.languageCode, let region = locale.regionCode {
            "\(language)_\(region)"
        } else {
            "en_US"
        }
        var dictionary = [
            Self.localeKey: localeIdentifier,
            Self.timeZoneKey: timeZone.abbreviation() ?? "UTC",
            Self.clientTimeKey: Self.dateFormatter.string(from: clientTime),
            Self.routingInfoKey: "\(routingInfo)",
            Self.machineIDKey: machineID,
            Self.localUserIDKey: localUserID,
            Self.oneTimePasswordKey: oneTimePassword,
        ]
        if let deviceID {
            dictionary[Self.deviceIDKey] = deviceID
        }
        return dictionary
    }

}
