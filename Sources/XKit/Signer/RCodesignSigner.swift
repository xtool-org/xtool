import Foundation
import RCodesign

public actor RCodesignSigner: Signer {

    public enum Error: LocalizedError {
        case badFilePath

        public var errorDescription: String? {
            switch self {
            case .badFilePath:
                return NSLocalizedString(
                    "signer_impl.error.bad_file_path", value: "A bad file path was provided", comment: ""
                )
            }
        }
    }

    public init() {}

    public func sign(
        app: URL,
        identity: SignerIdentity,
        entitlementMapping: [URL: Data],
        deep: Bool,
        progress: @escaping @Sendable (Double?) -> Void
    ) throws {
        progress(nil)
        guard app.isFileURL else { throw Error.badFilePath }
        let root = app.standardizedFileURL.pathComponents
        var entitlements: [String: Data] = [:]
        for (bundle, value) in entitlementMapping {
            let components = bundle.standardizedFileURL.pathComponents
            guard bundle.isFileURL, components.starts(with: root) else { throw Error.badFilePath }
            // RCodesign scopes entitlements by bundle-relative path: "" for the
            // app itself and e.g. "PlugIns/Widget.appex" for an extension. Compare
            // path components so a sibling such as App.app-copy cannot match App.app.
            let path = components.dropFirst(root.count).joined(separator: "/")
            guard entitlements[path] == nil else { throw Error.badFilePath }
            entitlements[path] = value
        }

        let signingIdentity: RCodesign.Identity
        switch identity {
        case .real(let certificate, let privateKey):
            signingIdentity = .certificate(certificateDER: try certificate.data(), privateKeyPEM: privateKey.data)
        case .adhoc:
            signingIdentity = .adHoc
        }
        try RCodesign.sign(at: app, identity: signingIdentity, options: .init(entitlements: entitlements, shallow: !deep))
    }

    public func analyze(executable: URL) throws -> Data? {
        try RCodesign.entitlements(at: executable)
    }

}
