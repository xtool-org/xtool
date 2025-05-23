import Foundation
import CXKit
import SignerSupport
import ConcurrencyExtras

/// a wrapper around `signer_t`
public actor Signer {

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

    public enum Identity {
        case real(Certificate, PrivateKey)
        case adhoc
    }

    private let signer: UnsafePointer<signer_t>
    public var name: String {
        String(cString: signer.pointee.name)
    }

    private init(signer: UncheckedSendable<UnsafePointer<signer_t>>) {
        self.signer = signer.value
    }

    public static func all() -> some Collection<Signer> {
        var list = get_signers()
        var arr: [Signer] = []
        while let curr = list {
            arr.append(Signer(signer: UncheckedSendable(curr)))
            list = curr.pointee.next
        }
        return arr
    }

    public static func first() throws -> Signer {
        try all().first.orThrow(Error.notFound)
    }

    private func _sign(
        app: URL,
        identity: Identity,
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

        let certificateData: Data
        let privateKeyData: Data
        let lengthOverride: Int?
        switch identity {
        case .real(let certificate, let privateKey):
            certificateData = try certificate.data()
            privateKeyData = privateKey.data
            lengthOverride = nil
        case .adhoc:
            // we can't use empty data here because withUnsafeBytes
            // might return a bufferpointer with a nil base address,
            // but signer.h expects non-null values. The real fix is
            // updating xtool-core/SignerSupport/signer.h to annotate
            // the pointers as nullable, but alas that requires effort.
            certificateData = Data([0])
            privateKeyData = Data([0])
            lengthOverride = 0
        }

        try certificateData.withUnsafeBytes { cert in
            try privateKeyData.withUnsafeBytes { priv in
                var exception: UnsafeMutablePointer<Int8>?
                defer { exception.map { free($0) } }

                let progress = sendableProgress.value
                let entsArray = sendableEntsArray.value

                guard let certBase = cert.baseAddress,
                    let privBase = priv.baseAddress
                    else { throw Error.signer(nil) }

                let box = Unmanaged.passRetained(progress as AnyObject)
                defer { box.release() }
                guard signer.pointee.sign(
                    app.path,
                    certBase, lengthOverride ?? cert.count,
                    privBase, lengthOverride ?? priv.count,
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
        identity: Identity,
        entitlementMapping: [URL: Entitlements],
        progress: @escaping (Double?) -> Void
    ) async throws {
        try self._sign(
            app: app,
            identity: identity,
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
