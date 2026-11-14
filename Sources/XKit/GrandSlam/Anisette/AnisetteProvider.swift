#if os(macOS) || os(Linux)
import Foundation
import Crypto
import Anisette
import XUtils
import Dependencies

/// Adapts the in-process virtual Mac runtime to XKit's provisioning flow.
struct AnisetteProvider: RawADIProvider {
    let providerID = "local-anisette-v1"
    let isLocal = true
    private let contextCache = OTPContextCache()

    func localUserID(for userID: UUID) -> String {
        let bytes = withUnsafeBytes(of: userID.uuid) { Data($0) }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func clientInfo() async throws -> ClientInfoWithUserAgent {
        let system: AnisetteSystemInfo
        do {
            system = try AnisetteSystemInfo.current()
        } catch {
            throw Self.explainingSetupFailure(error)
        }
        return ClientInfoWithUserAgent(
            clientInfo: system.clientInfo,
            akdUserAgent: system.akdUserAgent
        )
    }

    func startProvisioning(spim: Data, userID: UUID) async throws -> (RawADIProvisioningSession, Data) {
        // Provisioning replaces the state the cached context was built from.
        await contextCache.removeAll()
        let context = try await Self.openContext(userID: userID)
        do {
            let session = try await context.startProvisioning(challenge: spim)
            return (Session(context: context, session: session), session.clientChallenge)
        } catch {
            await context.close()
            throw error
        }
    }

    func requestOTP(
        userID: UUID,
        routingInfo: inout UInt64,
        provisioningInfo: inout Data
    ) async throws -> (machineID: Data, otp: Data) {
        let result = try await contextCache.requestOTP(userID: userID, state: provisioningInfo)
        provisioningInfo = result.provisioningState
        return (result.machineID, result.password)
    }

    private static func openContext(userID: UUID, state: Data = Data()) async throws -> AnisetteContext {
        @Dependency(\.anisetteConfiguration) var configuration
        do {
            return try await AnisetteContext.open(
                identifier: userID, provisioningState: state, configuration: configuration
            )
        } catch {
            throw explainingSetupFailure(error)
        }
    }

    /// Failures before ADI itself runs (downloads, verification, loading the
    /// emulator) are the ones the remote provider can work around.
    private static func explainingSetupFailure(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let error = error as? AnisetteError, error.adiStatus != nil { return error }
        return LocalAnisetteSetupError(underlying: error)
    }

    /// Opening a context costs seconds, and anisette is fetched for every
    /// GrandSlam and Developer Services request, so one context stays open per
    /// provider. It is reused only while the caller's state matches the state the
    /// context last produced; anything else (re-provisioning, another process
    /// advancing the stored state, an error) gets a fresh context.
    private actor OTPContextCache {
        private struct Entry {
            let userID: UUID
            let state: Data
            let context: AnisetteContext
        }
        private var entry: Entry?

        func requestOTP(userID: UUID, state: Data) async throws -> AnisetteContext.OTP {
            let context: AnisetteContext
            if let entry, entry.userID == userID, entry.state == state {
                // Take the entry so that a reentrant call never shares a context.
                self.entry = nil
                context = entry.context
            } else {
                await removeAll()
                context = try await openContext(userID: userID, state: state)
            }
            do {
                // A caller's cancellation would permanently cancel the shared
                // context, so let the OTP finish in its own task.
                let otp = try await Task { try await context.requestOTP() }.value
                await removeAll()
                entry = Entry(userID: userID, state: otp.provisioningState, context: context)
                return otp
            } catch {
                await context.close()
                throw error
            }
        }

        func removeAll() async {
            guard let context = entry?.context else { return }
            entry = nil
            await context.close()
        }
    }

    private struct Session: RawADIProvisioningSession {
        let context: AnisetteContext
        let session: AnisetteContext.ProvisioningSession
        func endProvisioning(routingInfo: UInt64, ptm: Data, tk: Data) async throws -> Data {
            defer { await context.close() }
            return try await session.finish(metadata: ptm, trustKey: tk)
        }
    }
}

public struct LocalAnisetteSetupError: Error, CustomStringConvertible {
    public let underlying: any Error

    public var description: String {
        """
        Could not set up local Anisette generation: \(underlying)

        As a fallback, you can use a remote Anisette server by setting \
        XTL_ANISETTE_PROVIDER=omnisette. You will need to log in again with `xtool auth`.
        """
    }
}

extension DependencyValues {
    var anisetteConfiguration: AnisetteConfiguration {
        get { self[AnisetteConfigurationKey.self] }
        set { self[AnisetteConfigurationKey.self] = newValue }
    }
}

private enum AnisetteConfigurationKey: DependencyKey {
    static var liveValue: AnisetteConfiguration {
        AnisetteConfiguration(cacheDirectory: XToolCache.directory.appendingPathComponent("anisette"))
    }
}
#endif
