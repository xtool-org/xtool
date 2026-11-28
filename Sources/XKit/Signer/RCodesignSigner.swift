import Foundation
import RCodesign

public actor RCodesignSigner: Signer {

    public enum Error: CustomStringConvertible, LocalizedError {
        case badFilePath

        public var description: String {
            switch self {
            case .badFilePath: "A bad file path was provided"
            }
        }

        public var errorDescription: String? { description }
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
            signingIdentity = .certificate(certificateDER: try certificate.data(), privateKeyPEM: try privateKey.pemData())
        case .adhoc:
            signingIdentity = .adHoc
        }

        var originalPermissions: [(String, Int)] = []
        try updatePermissions(dir: app) { path, permissions in
            originalPermissions.append((path, permissions))
            permissions = 0o644
        }
        let signResult = Result {
            try RCodesign.sign(at: app, identity: signingIdentity, options: .init(entitlements: entitlements, shallow: !deep))
        }
        for (path, permissions) in originalPermissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        }
        return try signResult.get()
    }

    private func updatePermissions(dir: URL, transform: (String, inout Int) throws -> Void) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { throw Error.badFilePath }
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == false else { continue }
            let path = file.path
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let permissions = attributes[.posixPermissions] as? Int else { continue }
            var newValue = permissions
            try transform(path, &newValue)
            guard newValue != permissions else { continue }
            try FileManager.default.setAttributes([.posixPermissions: newValue], ofItemAtPath: path)
        }
    }

    public func analyze(executable: URL) throws -> Data? {
        try RCodesign.entitlements(at: executable)
    }

}
