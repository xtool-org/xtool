#if os(macOS) || os(Linux)
import Foundation
import Dependencies
import Testing
import Anisette
@testable import XKit

@Suite(.serialized)
struct AnisetteProviderTests {
    @Test func identityHashesUUIDBytes() {
        let userID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let provider = AnisetteProvider()
        #expect(provider.localUserID(for: userID) == "a8faed6abbf35c12a4b26e40f6feb19d736d90045c83b9f9a31f638d323e6811")
        #expect(provider.providerID != OmnisetteADIProvider().providerID)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["XTOOL_TEST_LOCAL_ADI"] == "1"))
    func liveMachineProvisioningAndCachedOTP() async throws {
        let storage = MemoryKeyValueStorage()
        let directory = ProcessInfo.processInfo.environment["XTOOL_TEST_ANISETTE_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        try await withDependencies {
            $0.anisetteConfiguration = AnisetteConfiguration(appleDirectory: directory)
            $0.keyValueStorage = storage
            $0.rawADIProvider = AnisetteProvider()
            $0.httpClient = HTTPClientDependencyKey.liveValue
        } operation: {
            let provider = ADIDataProvider()
            try await withDependencies {
                $0.anisetteDataProvider = provider
            } operation: {
                let first = try await provider.fetchAnisetteData()
                #expect(!first.machineID.isEmpty)
                #expect(!first.oneTimePassword.isEmpty)
                #expect(first.routingInfo != 0)
                #expect(provider.provisioningData() != nil)
                let second = try await provider.fetchAnisetteData()
                #expect(second.machineID == first.machineID)
                #expect(!second.oneTimePassword.isEmpty)
                #expect(second.localUserID == first.localUserID)
            }
        }
    }
}
#endif
