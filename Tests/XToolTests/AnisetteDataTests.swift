import Foundation
import Testing
@testable import XKit

struct AnisetteDataTests {
    @Test(arguments: [
        (0.0, "1970-01-01T00:00:00Z"),
        (1_609_459_200.0, "2021-01-01T00:00:00Z"),
        (1_582_934_400.0, "2020-02-29T00:00:00Z"),
        (1_704_164_645.75, "2024-01-02T03:04:05Z"),
    ])
    func dictionaryFormatsClientTime(timestamp: TimeInterval, expected: String) {
        let data = AnisetteData(
            clientTime: Date(timeIntervalSince1970: timestamp),
            routingInfo: 123,
            machineID: "machine",
            localUserID: "user",
            oneTimePassword: "password",
            deviceInfo: DeviceInfo(
                deviceID: "device",
                clientInfo: "client",
                akdUserAgent: "agent"
            )
        )
        let localeIdentifier = if let language = data.locale.language.languageCode?.identifier,
                                  let region = data.locale.region?.identifier {
            "\(language)_\(region)"
        } else {
            "en_US"
        }
        let expectedDictionary = [
            "X-Apple-Locale": localeIdentifier,
            "X-Apple-I-TimeZone": data.timeZone.abbreviation() ?? "UTC",
            "X-Apple-I-Client-Time": expected,
            "X-Apple-I-MD-RINFO": "123",
            "X-Apple-I-MD-M": "machine",
            "X-Apple-I-MD-LU": "user",
            "X-Apple-I-MD": "password",
            "X-Mme-Device-Id": "device",
            "X-MMe-Client-Info": "client",
        ]

        #expect(data.dictionary == expectedDictionary)
        #expect(data.dictionary == expectedDictionary)
    }
}
