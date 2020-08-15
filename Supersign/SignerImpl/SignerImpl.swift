//
//  SignerImpl.swift
//  Supersign
//
//  Created by Kabir Oberai on 10/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

extension signer_t: CLinkedListElement {}

/// a wrapper around signer_t
public struct SignerImpl {

    private static let signingQueue = DispatchQueue(
        label: "com.kabiroberai.Supercharge.signing-queue",
        attributes: .concurrent
    )

    public enum Error: LocalizedError {
        case notFound
        case badFilePath
        case signer(String?)

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return NSLocalizedString(
                    "signer_impl.error.not_found", value: "No signer implementation found", comment: ""
                )
            case .badFilePath:
                return NSLocalizedString(
                    "signer_impl.error.bad_file_path", value: "A bad file path was provided", comment: ""
                )
            case .signer(let error?):
                return error
            case .signer(nil):
                return NSLocalizedString(
                    "signer_impl.error.unknown", value: "An unknown signing error occurred", comment: ""
                )
            }
        }
    }

    public let name: String
    private let sign: sign_func
    private let analyze: analyze_func

    private init(signer: signer_t) {
        name = String(cString: signer.name)
        sign = signer.sign
        analyze = signer.analyze
    }

    public static func all() -> AnyCollection<SignerImpl> {
        return AnyCollection(CLinkedList(first: signer_list).lazy.map(SignerImpl.init))
    }

    public static func first() throws -> SignerImpl {
        try all().first.orThrow(Error.notFound)
    }

    private func _sign(
        app: URL,
        certificate: Certificate,
        privateKey: PrivateKey,
        entitlementMapping: [URL: Entitlements],
        progress: @escaping (Double) -> Void
    ) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let entsArray: [entitlements_data_t] = try entitlementMapping.map { url, ents in
            try url.withUnsafeFileSystemRepresentation { bundlePath in
                guard let bundlePath = bundlePath else { throw Error.badFilePath }
                return try encoder.encode(ents).withUnsafeBytes { bytes in
                    // an XML plist should always be non-empty so force unwrapping baseAddress is safe
                    entitlements_data_t(bundle_path: bundlePath, data: bytes.baseAddress!, len: bytes.count)
                }
            }
        }
        try certificate.data().withUnsafeBytes { cert in
            try privateKey.data.withUnsafeBytes { priv in
                var exception: UnsafeMutablePointer<Int8>?
                defer { exception.map { free($0) } }

                guard let certBase = cert.baseAddress,
                    let privBase = priv.baseAddress
                    else { throw Error.signer(nil) }

                guard sign(
                    app.path,
                    certBase, cert.count,
                    privBase, priv.count,
                    entsArray, entsArray.count,
                    progress,
                    &exception
                ) == 0 else {
                    throw Error.signer(exception.map { String(cString: $0) })
                }
            }
        }
    }

    public func sign(
        app: URL,
        certificate: Certificate,
        privateKey: PrivateKey,
        entitlementMapping: [URL: Entitlements],
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<(), Swift.Error>) -> Void
    ) {
        Self.signingQueue.async {
            do {
                try self._sign(
                    app: app,
                    certificate: certificate,
                    privateKey: privateKey,
                    entitlementMapping: entitlementMapping,
                    progress: progress
                )
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    public func analyze(executable: URL) throws -> Data {
        try executable.withUnsafeFileSystemRepresentation { (path: UnsafePointer<Int8>?) -> Data in
            guard let path = path else { throw Error.badFilePath }
            var exception: UnsafeMutablePointer<Int8>?
            defer { exception.map { free($0) } }
            return try Data { analyze(path, &$0, &exception) }
                .orThrow(Error.signer(exception.map { String(cString: $0) }))
        }
    }

}
