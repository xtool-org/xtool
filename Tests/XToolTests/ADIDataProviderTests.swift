import Foundation
import ConcurrencyExtras
import Dependencies
import Testing
@testable import XKit

struct ADIDataProviderTests {
    private struct CountingStorage: KeyValueStorage {
        let backing = MemoryKeyValueStorage()
        let writes = LockIsolated<[String: Int]>([:])

        func data(forKey key: String) throws -> Data? { try backing.data(forKey: key) }
        func setData(_ data: Data?, forKey key: String) throws {
            writes.withValue { $0[key, default: 0] += 1 }
            try backing.setData(data, forKey: key)
        }
    }

    private struct StubProvider: RawADIProvider {
        let providerID: String
        let isLocal = true
        let otp: @Sendable (inout UInt64, inout Data) async throws -> (Data, Data)

        func localUserID(for userID: UUID) -> String { userID.uuidString }

        func clientInfo() async throws -> ClientInfoWithUserAgent {
            .init(clientInfo: "client", akdUserAgent: "agent")
        }

        func startProvisioning(spim: Data, userID: UUID) async throws -> (RawADIProvisioningSession, Data) {
            Issue.record("Cached provisioning should be reused")
            throw CancellationError()
        }

        func requestOTP(
            userID: UUID,
            routingInfo: inout UInt64,
            provisioningInfo: inout Data
        ) async throws -> (machineID: Data, otp: Data) {
            try await otp(&routingInfo, &provisioningInfo)
        }
    }

    private static func seed(_ storage: some KeyValueStorage, providerID: String, state: Data) throws {
        try storage.setString(providerID, forKey: "XTLADIProviderID")
        try storage.setData(state, forKey: "XTLProvisioningInfo")
        try storage.setString("123", forKey: "XTLRoutingInfo")
    }

    @Test func unchangedOTPStateDoesNotWriteStorage() async throws {
        let storage = CountingStorage()
        let stub = StubProvider(providerID: "test-unchanged-adi") { _, _ in
            (Data("machine".utf8), Data("otp".utf8))
        }
        try Self.seed(storage.backing, providerID: stub.providerID, state: Data("old".utf8))
        try await withDependencies {
            $0.keyValueStorage = storage
            $0.rawADIProvider = stub
        } operation: {
            let provider = ADIDataProvider()
            _ = try await provider.fetchAnisetteData()
            _ = try await provider.fetchAnisetteData()
            #expect(storage.writes.value["XTLProvisioningInfo"] == nil)
            #expect(storage.writes.value["XTLRoutingInfo"] == nil)
        }
    }

    @Test func concurrentRequestsAdvanceStateOnceEach() async throws {
        let storage = MemoryKeyValueStorage()
        let stub = StubProvider(providerID: "test-incrementing-adi") { _, provisioningInfo in
            let previous = provisioningInfo[provisioningInfo.startIndex]
            try await Task.sleep(for: .milliseconds(50))
            provisioningInfo = Data([previous + 1])
            return (Data("machine".utf8), Data([previous]))
        }
        try Self.seed(storage, providerID: stub.providerID, state: Data([0]))
        try await withDependencies {
            $0.keyValueStorage = storage
            $0.rawADIProvider = stub
        } operation: {
            let first = ADIDataProvider()
            let second = ADIDataProvider()
            async let firstData = first.fetchAnisetteData()
            async let secondData = second.fetchAnisetteData()
            let passwords = try await [firstData.oneTimePassword, secondData.oneTimePassword]
            #expect(Set(passwords) == Set([Data([0]).base64EncodedString(), Data([1]).base64EncodedString()]))
            #expect(try storage.data(forKey: "XTLProvisioningInfo") == Data([2]))
        }
    }

    private static let updatingProvider = StubProvider(providerID: "test-local-adi") { routingInfo, provisioningInfo in
        #expect(provisioningInfo == Data("old".utf8))
        #expect(routingInfo == 123)
        provisioningInfo = Data("new".utf8)
        routingInfo = 456
        return (Data("machine".utf8), Data("otp".utf8))
    }

    @Test func persistsUpdatedOTPStateAndRoutingInfo() async throws {
        let storage = MemoryKeyValueStorage()
        try Self.seed(storage, providerID: Self.updatingProvider.providerID, state: Data("old".utf8))
        try await withDependencies {
            $0.keyValueStorage = storage
            $0.rawADIProvider = Self.updatingProvider
        } operation: {
            let provider = ADIDataProvider()
            let data = try await provider.fetchAnisetteData()
            #expect(data.routingInfo == 456)
            #expect(data.machineID == Data("machine".utf8).base64EncodedString())
            #expect(provider.provisioningData()?.adiPb == Data("new".utf8))
            #expect(provider.provisioningData()?.routingInfo == 456)
            #expect(provider.providerID == Self.updatingProvider.providerID)
        }
    }

    @Test func changingProviderInvalidatesProvisioning() throws {
        let storage = MemoryKeyValueStorage()
        try Self.seed(storage, providerID: "mac-omnisette", state: Data("old".utf8))
        let userID = UUID().uuidString
        try storage.setString(userID, forKey: "XTLLocalUserUID")
        try withDependencies {
            $0.keyValueStorage = storage
            $0.rawADIProvider = Self.updatingProvider
        } operation: {
            let provider = ADIDataProvider()
            #expect(provider.provisioningData() == nil)
            let savedUserID = try storage.string(forKey: "XTLLocalUserUID")
            #expect(savedUserID == userID)
            #expect(try storage.string(forKey: "XTLADIProviderID") == "mac-omnisette")
        }
    }

    @Test func anisetteProviderOverride() {
        typealias Key = RawADIProviderDependencyKey
        #expect(Key.provider(named: "omnisette") is OmnisetteADIProvider)
        #if os(macOS) || os(Linux)
        #expect(Key.provider(named: nil) is AnisetteProvider)
        #expect(Key.provider(named: "local") is AnisetteProvider)
        #expect(Key.provider(named: "bogus") is AnisetteProvider)
        #else
        #expect(Key.provider(named: nil) is OmnisetteADIProvider)
        #endif
    }
}
