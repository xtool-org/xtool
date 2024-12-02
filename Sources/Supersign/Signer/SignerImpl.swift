//
//  SignerImpl.swift
//  Supersign
//
//  Created by Kabir Oberai on 10/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import CSupersign
import SignerSupport
import ConcurrencyExtras

/// a wrapper around signer_t
public actor SignerImpl {

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

    private let signer: UnsafePointer<signer_t>
    public var name: String {
        String(cString: signer.pointee.name)
    }

    private init(signer: UncheckedSendable<UnsafePointer<signer_t>>) {
        self.signer = signer.value
    }

    public static func all() -> some Collection<SignerImpl> {
        var list = get_signers()
        var arr: [SignerImpl] = []
        while let curr = list {
            arr.append(SignerImpl(signer: UncheckedSendable(curr)))
            list = curr.pointee.next
        }
        return arr
    }

    public static func first() throws -> SignerImpl {
        try all().first.orThrow(Error.notFound)
    }

    private func _sign(
        app: URL,
        certificate: Certificate,
        privateKey: PrivateKey,
        entitlementMapping: [URL: Entitlements],
        progress: @escaping (Double?) -> Void
    ) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let entsArray: [entitlements_data_t] = try entitlementMapping.map { url, ents in
            try url.withUnsafeFileSystemRepresentation { bundlePath in
                guard let bundlePath = bundlePath else { throw Error.badFilePath }
                return try encoder.encode(ents).withUnsafeBytes { bytes in
                    let copy = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
                    bytes.copyBytes(to: copy)
                    // an XML plist should always be non-empty so force unwrapping baseAddress is safe
                    return entitlements_data_t(
                        bundle_path: strdup(bundlePath),
                        data: copy.baseAddress!,
                        len: copy.count
                    )
                }
            }
        }
        defer {
            entsArray.forEach {
                free(UnsafeMutablePointer(mutating: $0.bundle_path))
                $0.data.deallocate()
            }
        }
        let sendableProgress = UncheckedSendable(progress)
        let sendableEntsArray = UncheckedSendable(entsArray)
        try certificate.data().withUnsafeBytes { cert in
            let sendableCert = UncheckedSendable(cert)
            try privateKey.data.withUnsafeBytes { priv in
                var exception: UnsafeMutablePointer<Int8>?
                defer { exception.map { free($0) } }

                let progress = sendableProgress.value
                let cert = sendableCert.value
                let entsArray = sendableEntsArray.value

                guard let certBase = cert.baseAddress,
                    let privBase = priv.baseAddress
                    else { throw Error.signer(nil) }

                let box = Unmanaged.passRetained(progress as AnyObject)
                defer { box.release() }
                guard signer.pointee.sign(
                    app.path,
                    certBase, cert.count,
                    privBase, priv.count,
                    entsArray, entsArray.count,
                    {
                        // swiftlint:disable:previous opening_brace
                        (Unmanaged<AnyObject>
                            .fromOpaque($0)
                            .takeUnretainedValue()
                         // swiftlint:disable:next force_cast
                         as! (Double?) -> Void
                        )($1 == -1 ? nil : $1)
                    },
                    box.toOpaque(),
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
        progress: @escaping (Double?) -> Void
    ) async throws {
        try self._sign(
            app: app,
            certificate: certificate,
            privateKey: privateKey,
            entitlementMapping: entitlementMapping,
            progress: progress
        )
    }

    public func analyze(executable: URL) throws -> Data {
        try executable.withUnsafeFileSystemRepresentation { (path: UnsafePointer<Int8>?) -> Data in
            guard let path = path else { throw Error.badFilePath }
            var exception: UnsafeMutablePointer<Int8>?
            defer { exception.map { free($0) } }
            var count = 0
            guard let bytes = signer.pointee.analyze(path, &count, &exception)
                  else { throw Error.signer(exception.map { String(cString: $0) })}
            return Data(bytesNoCopy: bytes, count: count, deallocator: .free)
        }
    }

}
