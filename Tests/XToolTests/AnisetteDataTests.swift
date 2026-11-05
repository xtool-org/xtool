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
        #expect(data.dictionary["X-Apple-I-Client-Time"] == expected)
    }
}
