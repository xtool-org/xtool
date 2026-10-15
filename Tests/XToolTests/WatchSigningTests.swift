import DeveloperAPI
import Foundation
import Testing
@testable import XKit
@testable import XToolSupport

@Test func watchProfilesSelectWatchDevices() {
    typealias DeviceClass = Components.Schemas.Device.AttributesPayload.DeviceClassPayload.Value1Payload
    #expect(DeviceClass.appleWatch.supportsApps(on: .watchOS))
    #expect(!DeviceClass.iphone.supportsApps(on: .watchOS))
    #expect(!DeviceClass.ipad.supportsApps(on: .watchOS))
    #expect(DeviceClass.iphone.supportsApps(on: .iOS))
    #expect(DeviceClass.ipad.supportsApps(on: .iOS))
    #expect(!DeviceClass.appleWatch.supportsApps(on: .iOS))
}

@Test func watchSigningDelegateRefusesRevocationWithoutPrompting() async {
    let certificate = DeveloperServicesCertificate(
        _type: .certificates,
        id: "1",
        attributes: .init(name: "Development", expirationDate: Date())
    )
    let delegate = XToolInstallerDelegate(allowsRevocation: false)
    let confirmed = await delegate.confirmRevocation(of: [certificate])
    let refused = await delegate.refusedRevocation
    #expect(!confirmed)
    #expect(refused)
}
