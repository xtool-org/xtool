import DeveloperAPI
import Testing
@testable import XKit

@Test func watchProfilesSelectWatchDevices() {
    typealias DeviceClass = Components.Schemas.Device.AttributesPayload.DeviceClassPayload.Value1Payload
    #expect(DeviceClass.appleWatch.supportsApps(on: .watchOS))
    #expect(!DeviceClass.iphone.supportsApps(on: .watchOS))
    #expect(!DeviceClass.ipad.supportsApps(on: .watchOS))
    #expect(DeviceClass.iphone.supportsApps(on: .iOS))
    #expect(DeviceClass.ipad.supportsApps(on: .iOS))
    #expect(!DeviceClass.appleWatch.supportsApps(on: .iOS))
}
