import Foundation
import Crypto
import X509
import XUtils

/// A reader for Apple Encrypted Archives (`.aea`).
///
/// Only the signed, unencrypted profile (`hkdf_sha256_hmac__none__ecdsa_p256`)
/// is currently supported. This is the profile used to distribute Xcode.
///
/// Opening an archive validates its prologue (the ECDSA signature and the root
/// header MAC), and segment data is authenticated as it is decoded. Note that
/// the signing certificate itself is not validated, so this only guarantees
/// integrity, not authenticity.
final class AEAArchive: Sendable {
    struct Options: Sendable {
        /// How to determine the key that the archive was signed with.
        var signingKey: SigningKey = .embeddedCertificate

        /// The maximum number of segments to decode concurrently. Each one
        /// needs up to twice the archive's segment size in memory.
        var maxConcurrentSegments = min(ProcessInfo.processInfo.activeProcessorCount, 8)
    }

    enum SigningKey: Sendable {
        /// Use the leaf of the archive's embedded certificate chain.
        case embeddedCertificate

        /// Use the provided key.
        case publicKey(P256.Signing.PublicKey)
    }

    struct RootHeader: Hashable, Sendable {
        /// The size of the decoded (plaintext) stream.
        var rawSize: UInt64
        /// The size of the encoded archive.
        var containerSize: UInt64
        var segmentSize: UInt32
        var segmentsPerCluster: UInt32
        var compression: AEACompressionAlgorithm
        var checksum: AEAChecksumAlgorithm
    }

    static let certificateChainKey = "com.apple.ias.signature.certificate-chain"

    let rootHeader: RootHeader

    private let authData: Data
    private let signingPublicKey: P256.Signing.PublicKey

    private let fd: FileDescriptor
    private let mainKey: SymmetricKey
    private let firstClusterOffset: Int64
    private let firstClusterMAC: Data
    private let options: Options

    private static let prologueSize = 304
    private static let signatureSize = 128
    private static let macSize = 32

    convenience init(path: FilePath, options: Options = .init()) throws {
        let fd = try FileDescriptor.open(path, .readOnly)
        do {
            try self.init(fileDescriptor: fd, options: options)
        } catch {
            try? fd.close()
            throw error
        }
    }

    /// On success, the archive takes ownership of `fileDescriptor`.
    private init(fileDescriptor fd: FileDescriptor, options: Options = .init()) throws {
        self.fd = fd
        self.options = options

        let fileSize = try fd.seek(offset: 0, from: .end)

        let header = try fd.readExactly(count: 12, at: 0)
        guard header.prefix(4) == Data("AEA1".utf8) else {
            throw AEAError("Not an Apple Encrypted Archive (bad magic)")
        }
        // low 24 bits: profile, high 8 bits: scrypt strength. We only support
        // profile 0 (signed, unencrypted), where the scrypt strength is unused.
        let rawProfile = header.loadLE(UInt32.self, at: 4)
        guard rawProfile == 0 else {
            throw AEAError("Unsupported AEA profile: \(rawProfile & 0xFF_FFFF) (scrypt strength \(rawProfile >> 24))")
        }

        let authDataSize = Int(header.loadLE(UInt32.self, at: 8))
        let authEnd = 12 + authDataSize
        guard Int64(authEnd + Self.prologueSize) <= fileSize else {
            throw AEAError("Archive is truncated")
        }
        let prologue = try fd.readExactly(count: authEnd + Self.prologueSize, at: 0)
        authData = prologue.bytes(at: 12, count: authDataSize)

        var cursor = authEnd
        func take(_ count: Int) -> Data {
            defer { cursor += count }
            return prologue.bytes(at: cursor, count: count)
        }
        let signature = take(Self.signatureSize)
        let keyMaterial = take(32)
        let salt = take(32)
        let rootHeaderMAC = take(Self.macSize)
        let rootHeaderBytes = take(48)
        firstClusterMAC = take(Self.macSize)
        firstClusterOffset = Int64(cursor)

        signingPublicKey = try Self.signingKey(authData: authData, source: options.signingKey)

        // The signature covers the SHA-256 digest of the prologue, with the
        // signature itself zeroed.
        var signedPrologue = prologue
        signedPrologue.replaceSubrange(
            (prologue.startIndex + authEnd)..<(prologue.startIndex + authEnd + Self.signatureSize),
            with: Data(count: Self.signatureSize)
        )
        guard let derSignature = Self.trimDERSignature(signature),
              let ecdsaSignature = try? P256.Signing.ECDSASignature(derRepresentation: derSignature),
              signingPublicKey.isValidSignature(ecdsaSignature, for: SHA256.hash(data: signedPrologue))
        else { throw AEAError("Invalid archive signature") }

        var info = Data("AEA_AMK".utf8)
        info.appendLE(rawProfile)
        info.append(signingPublicKey.x963Representation)
        mainKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: keyMaterial),
            salt: salt,
            info: info,
            outputByteCount: 32
        )

        let rootHeaderKey = Self.macKey(from: mainKey, info: Data("AEA_RHEK".utf8))
        guard Self.mac(key: rootHeaderKey, salt: [firstClusterMAC, authData], data: rootHeaderBytes)
                == rootHeaderMAC else {
            throw AEAError("Root header MAC mismatch (corrupt archive or wrong signing key)")
        }

        rootHeader = RootHeader(
            rawSize: rootHeaderBytes.loadLE(at: 0),
            containerSize: rootHeaderBytes.loadLE(at: 8),
            segmentSize: rootHeaderBytes.loadLE(at: 16),
            segmentsPerCluster: rootHeaderBytes.loadLE(at: 20),
            compression: AEACompressionAlgorithm(rawValue: rootHeaderBytes[rootHeaderBytes.startIndex + 24]),
            checksum: AEAChecksumAlgorithm(rawValue: rootHeaderBytes[rootHeaderBytes.startIndex + 25])
        )
        guard rootHeader.containerSize == UInt64(fileSize) else {
            throw AEAError("Archive size mismatch: expected \(rootHeader.containerSize), got \(fileSize)")
        }
        guard rootHeader.segmentSize > 0, rootHeader.segmentSize <= 256 << 20,
              rootHeader.segmentsPerCluster > 0, rootHeader.segmentsPerCluster <= 256 << 10
        else { throw AEAError("Invalid segment layout") }
        guard rootHeader.checksum.size != nil else {
            throw AEAError("Unsupported checksum algorithm: \(rootHeader.checksum.rawValue)")
        }
        guard rootHeader.compression.isSupported else {
            throw AEAError("Unsupported compression algorithm: \(rootHeader.compression)")
        }
    }

    deinit {
        try? fd.close()
    }

    // MARK: - Decoding

    /// Decodes the archive, calling `body` with each consecutive chunk of the
    /// plaintext stream.
    ///
    /// Segments are decoded concurrently but `body` is invoked serially,
    /// in order. Supports cooperative cancellation.
    func decode(
        progress: ((AEAProgress) -> Void)? = nil,
        into body: (Data) async throws -> Void
    ) async throws {
        let maxConcurrent = max(1, options.maxConcurrentSegments)
        let total = rootHeader.rawSize
        var completed: UInt64 = 0
        progress?(AEAProgress(completedBytes: 0, totalBytes: total))

        var segments = SegmentIterator(archive: self)
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var running = 0
            var finished: [Int: Data] = [:]
            var nextToEmit = 0

            func receive() async throws {
                guard let (index, data) = try await group.next() else { return }
                running -= 1
                finished[index] = data
                while let data = finished.removeValue(forKey: nextToEmit) {
                    try Task.checkCancellation()
                    try await body(data)
                    nextToEmit += 1
                    completed += UInt64(data.count)
                    progress?(AEAProgress(completedBytes: completed, totalBytes: total))
                }
            }

            while let segment = try segments.next() {
                try Task.checkCancellation()
                // bound memory usage: segments that are finished but blocked
                // on an earlier one still count towards the limit.
                while running + finished.count >= maxConcurrent {
                    try await receive()
                }
                group.addTask {
                    (segment.index, try self.decodeSegment(segment))
                }
                running += 1
            }
            while running > 0 {
                try await receive()
            }
        }

        guard completed == total else {
            throw AEAError("Decoded \(completed) bytes, expected \(total)")
        }
    }

    /// Writes the decoded plaintext stream to `path`.
    func decode(
        to path: FilePath,
        progress: ((AEAProgress) -> Void)? = nil
    ) async throws {
        let out = try FileDescriptor.open(
            path, .writeOnly,
            options: [.create, .truncate],
            permissions: [.ownerReadWrite, .groupRead, .otherRead]
        )
        defer { try? out.close() }
        try await decode(progress: progress) { data in
            try data.withUnsafeBytes { _ = try out.writeAll($0) }
        }
    }

    /// Extracts the Apple Archive contained in this AEA into `directory`.
    func extract(
        to directory: FilePath,
        filter: ((String) -> Bool)? = nil,
        progress: ((AEAProgress) -> Void)? = nil
    ) async throws {
        let extractor = try AppleArchiveExtractor(destination: directory, filter: filter)
        var decoder = AppleArchiveDecoder()
        try await decode(progress: progress) { data in
            try decoder.decode(data) { try extractor.handle($0) }
        }
        try decoder.finish()
        try extractor.finish()
    }

    // MARK: - Segments

    fileprivate struct Segment: Sendable {
        var index: Int
        var offset: Int64
        var compressedSize: Int
        var rawSize: Int
        var checksum: Data
        var mac: Data
        var macKey: SymmetricKey
    }

    private struct SegmentIterator {
        let archive: AEAArchive
        var cluster: UInt32 = 0
        var offset: Int64
        var expectedClusterMAC: Data
        var pending: [Segment] = []
        var emitted = 0
        var remaining: UInt64

        init(archive: AEAArchive) {
            self.archive = archive
            offset = archive.firstClusterOffset
            expectedClusterMAC = archive.firstClusterMAC
            remaining = archive.rootHeader.rawSize
        }

        mutating func next() throws -> Segment? {
            while pending.isEmpty {
                guard remaining > 0 else {
                    try archive.verifyPadding(at: offset, expectedMAC: expectedClusterMAC)
                    return nil
                }
                try readCluster()
            }
            return pending.removeFirst()
        }

        private mutating func readCluster() throws {
            let root = archive.rootHeader
            let count = Int(root.segmentsPerCluster)
            let entrySize = 8 + root.checksum.size!
            let entriesSize = count * entrySize
            let headerSize = entriesSize + AEAArchive.macSize * (count + 1)

            let header = try archive.fd.readExactly(count: headerSize, at: offset)
            offset += Int64(headerSize)
            let entries = header.bytes(at: 0, count: entriesSize)
            let macs = header.bytes(at: entriesSize, count: headerSize - entriesSize)

            var clusterInfo = Data("AEA_CK".utf8)
            clusterInfo.appendLE(cluster)
            let clusterKey = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: archive.mainKey,
                salt: Data(),
                info: clusterInfo,
                outputByteCount: 32
            )
            let headerKey = AEAArchive.macKey(from: clusterKey, info: Data("AEA_CHEK".utf8))
            guard AEAArchive.mac(key: headerKey, salt: [macs], data: entries) == expectedClusterMAC else {
                throw AEAError("Cluster \(cluster) header MAC mismatch")
            }
            expectedClusterMAC = macs.bytes(at: 0, count: AEAArchive.macSize)

            let segmentPRK = HKDF<SHA256>.extract(inputKeyMaterial: clusterKey, salt: Data())
            for i in 0..<count {
                let entry = entries.bytes(at: i * entrySize, count: entrySize)
                let rawSize = Int(entry.loadLE(UInt32.self, at: 0))
                let compressedSize = Int(entry.loadLE(UInt32.self, at: 4))
                let expectedSize = Int(min(UInt64(root.segmentSize), remaining))
                guard rawSize == expectedSize else {
                    throw AEAError("Segment \(i) of cluster \(cluster) has size \(rawSize), expected \(expectedSize)")
                }
                if expectedSize == 0 {
                    guard compressedSize == 0 else {
                        throw AEAError("Unused segment \(i) of cluster \(cluster) is not empty")
                    }
                    continue
                }
                guard compressedSize > 0, compressedSize <= rawSize,
                      offset + Int64(compressedSize) <= Int64(root.containerSize)
                else {
                    throw AEAError("Segment \(i) of cluster \(cluster) has invalid size \(compressedSize)")
                }

                var segmentInfo = Data("AEA_SK".utf8)
                segmentInfo.appendLE(UInt32(i))
                let segmentKey = HKDF<SHA256>.expand(
                    pseudoRandomKey: segmentPRK,
                    info: segmentInfo,
                    outputByteCount: 32
                )

                pending.append(Segment(
                    index: emitted,
                    offset: offset,
                    compressedSize: compressedSize,
                    rawSize: rawSize,
                    checksum: entry.bytes(at: 8, count: entrySize - 8),
                    mac: macs.bytes(at: AEAArchive.macSize * (i + 1), count: AEAArchive.macSize),
                    macKey: segmentKey
                ))
                emitted += 1
                offset += Int64(compressedSize)
                remaining -= UInt64(rawSize)
            }
            cluster += 1
        }
    }

    private func decodeSegment(_ segment: Segment) throws -> Data {
        let stored = try fd.readExactly(count: segment.compressedSize, at: segment.offset)
        guard Self.mac(key: segment.macKey, salt: [], data: stored) == segment.mac else {
            throw AEAError("Segment \(segment.index) MAC mismatch")
        }
        let compression: AEACompressionAlgorithm = segment.compressedSize == segment.rawSize
            ? .none
            : rootHeader.compression
        let raw = try compression.decompress(stored, size: segment.rawSize)

        switch rootHeader.checksum {
        case .sha256:
            guard Data(SHA256.hash(data: raw)) == segment.checksum else {
                throw AEAError("Segment \(segment.index) checksum mismatch")
            }
        case .murmur64:
            guard murmur64(raw) == segment.checksum.loadLE(UInt64.self, at: 0) else {
                throw AEAError("Segment \(segment.index) checksum mismatch")
            }
        default:
            break
        }
        return raw
    }

    private func verifyPadding(at offset: Int64, expectedMAC: Data) throws {
        let size = Int64(rootHeader.containerSize) - offset
        guard size > 0 else { return }
        let key = Self.macKey(from: mainKey, info: Data("AEA_PAK".utf8))
        var hmac = HMAC<SHA256>(key: key)
        var position = offset
        while position < offset + size {
            try Task.checkCancellation()
            let chunk = try fd.readExactly(count: Int(min(1 << 20, offset + size - position)), at: position)
            hmac.update(data: chunk)
            position += Int64(chunk.count)
        }
        guard Data(hmac.finalize()) == expectedMAC else {
            throw AEAError("Padding MAC mismatch")
        }
    }

    // MARK: - Crypto helpers

    /// Derives the MAC key of an HKDF data key.
    private static func macKey(from key: SymmetricKey, info: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(), info: info, outputByteCount: 32)
    }

    /// HMAC-SHA256 over `salt || data || LE64(salt.count)`.
    private static func mac(key: SymmetricKey, salt: [Data], data: Data) -> Data {
        var hmac = HMAC<SHA256>(key: key)
        var saltSize: UInt64 = 0
        for part in salt {
            hmac.update(data: part)
            saltSize += UInt64(part.count)
        }
        hmac.update(data: data)
        var suffix = Data()
        suffix.appendLE(saltSize)
        hmac.update(data: suffix)
        return Data(hmac.finalize())
    }

    /// Strips the zero padding from a DER-encoded ECDSA signature.
    private static func trimDERSignature(_ signature: Data) -> Data? {
        guard signature.count >= 2, signature[signature.startIndex] == 0x30 else { return nil }
        let length = Int(signature[signature.startIndex + 1])
        // P-256 signatures are always short enough for the short-form length.
        guard length < 0x80, 2 + length <= signature.count else { return nil }
        return signature.prefix(2 + length)
    }

    // MARK: - Signing key

    private static func signingKey(authData: Data, source: SigningKey) throws -> P256.Signing.PublicKey {
        switch source {
        case .publicKey(let key):
            return key
        case .embeddedCertificate:
            return try embeddedSigningKey(authData: authData)
        }
    }

    /// The public key of the leaf certificate in the auth data's certificate chain.
    static func embeddedSigningKey(authData: Data) throws -> P256.Signing.PublicKey {
        guard let entries = parseAuthData(authData),
              let pem = entries.first(where: { $0.key == certificateChainKey })?.value
        else { throw AEAError("Archive does not contain a signing certificate chain") }
        // the leaf comes first
        guard let leaf = String(decoding: pem, as: UTF8.self).components(separatedBy: endMarker).first,
              let certificate = try? Certificate(pemEncoded: leaf + endMarker),
              let key = P256.Signing.PublicKey(certificate.publicKey)
        else { throw AEAError("Archive does not contain a valid P-256 signing certificate") }
        return key
    }

    private static let endMarker = "-----END CERTIFICATE-----"

    private static func parseAuthData(_ data: Data) -> [(key: String, value: Data)]? {
        var entries: [(key: String, value: Data)] = []
        var offset = 0
        while offset < data.count {
            guard data.count - offset >= 4 else { return nil }
            let size = Int(data.loadLE(UInt32.self, at: offset))
            guard size > 4, size <= data.count - offset else { return nil }
            let payload = data.bytes(at: offset + 4, count: size - 4)
            guard let nul = payload.firstIndex(of: 0) else { return nil }
            entries.append((
                key: String(decoding: payload[..<nul], as: UTF8.self),
                value: Data(payload[(nul + 1)...])
            ))
            offset += size
        }
        return entries
    }
}

struct AEAProgress: Sendable, Hashable {
    /// The number of plaintext bytes decoded so far.
    var completedBytes: UInt64
    /// The total number of plaintext bytes in the archive.
    var totalBytes: UInt64

    var fractionCompleted: Double {
        totalBytes == 0 ? 1 : Double(completedBytes) / Double(totalBytes)
    }
}

extension FileDescriptor {
    fileprivate func readExactly(count: Int, at offset: Int64) throws -> Data {
        var data = Data(count: count)
        let read = try data.withUnsafeMutableBytes { buf in
            var total = 0
            while total < count {
                let n = try self.read(
                    fromAbsoluteOffset: offset + Int64(total),
                    into: UnsafeMutableRawBufferPointer(rebasing: buf[total...])
                )
                if n == 0 { break }
                total += n
            }
            return total
        }
        guard read == count else { throw AEAError("Archive is truncated") }
        return data
    }
}
