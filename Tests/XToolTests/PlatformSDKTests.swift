import Testing
@testable import PackLib

@Test func xcodeVersionCodeMatchesXcode() {
    #expect(PlatformSDK.xcodeVersionCode("26.6") == "2660")
    #expect(PlatformSDK.xcodeVersionCode("26.0.1") == "2601")
    #expect(PlatformSDK.xcodeVersionCode("27") == "2700")
    #expect(PlatformSDK.xcodeVersionCode("9.4") == "0940")
    #expect(PlatformSDK.xcodeVersionCode("26.10") == nil)
    #expect(PlatformSDK.xcodeVersionCode("beta") == nil)
}
