import Foundation
import Dependencies

public enum SignerIdentity: Sendable {
    case real(Certificate, PrivateKey)
    case adhoc
}

public protocol Signer: Sendable {
    // entitlementMapping is [bundle url] -> [plist data]
    func sign(
        app: URL,
        identity: SignerIdentity,
        entitlementMapping: [URL: Data],
        deep: Bool,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws

    func analyze(executable: URL) async throws -> Data?
}

private enum SignerDependencyKey: DependencyKey {
    static var liveValue: any Signer { RCodesignSigner() }
    static var testValue: any Signer { UnimplementedSigner() }
}

extension DependencyValues {
    public var signer: any Signer {
        get { self[SignerDependencyKey.self] }
        set { self[SignerDependencyKey.self] = newValue }
    }
}

private struct UnimplementedSigner: Signer {
    func sign(
        app: URL,
        identity: SignerIdentity,
        entitlementMapping: [URL: Data],
        deep: Bool,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        reportIssue("Unimplemented: Signer.sign")
        throw UnimplementedFailure(description: "Signer.sign")
    }

    func analyze(executable: URL) async throws -> Data? {
        reportIssue("Unimplemented: Signer.analyze")
        throw UnimplementedFailure(description: "Signer.analyze")
    }
}
