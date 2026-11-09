import Foundation
import Testing
import ConcurrencyExtras
import Crypto
@testable import XAppleArchive
import XUtils

// Fixtures were created with `aa archive -a raw` and
// `aea encrypt -profile 0 -sign-priv <key> -b 16k`.
private let fixtures = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures")

// swiftlint:disable:next force_try
private let fixtureKey = try! P256.Signing.PublicKey(x963Representation: Data(hex:
    "04c001feac563995c90c0ba02909e5c0cf80d8da04fb19493b7bbbeceeee7cd37e"
    + "01818da73a57e8f5dadeadca2da926a9e4ca83c075f81ef0143a9522b7082369"
))

private let fixtureOptions = AEAArchive.Options(signingKey: .publicKey(fixtureKey))

private func fixture(_ name: String) -> FilePath {
    FilePath(fixtures.appending(path: name).path)
}

private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "xtool-aa-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        // the fixture contains a read-only directory
        _ = try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: dir.appending(path: "dir/sub").path
        )
        try? FileManager.default.removeItem(at: dir)
    }
    return try await body(dir)
}

private func checkSmallTree(at dir: URL, hardLinks: Bool = true) throws {
    let fm = FileManager.default
    #expect(try String(contentsOf: dir.appending(path: "hello.txt"), encoding: .utf8) == "hello world\n")
    #expect(try String(contentsOf: dir.appending(path: "dir/run.sh"), encoding: .utf8) == "#!/bin/sh\necho hi\n")
    #expect(try fm.destinationOfSymbolicLink(atPath: dir.appending(path: "dir/link").path) == "../hello.txt")

    func attributes(_ path: String) throws -> [FileAttributeKey: Any] {
        try fm.attributesOfItem(atPath: dir.appending(path: path).path)
    }
    #expect(try attributes("dir/run.sh")[.posixPermissions] as? Int == 0o755)
    #expect(try attributes("hello.txt")[.posixPermissions] as? Int == 0o644)
    #expect(try attributes("dir/sub")[.posixPermissions] as? Int == 0o555)
    #expect(try attributes("dir/sub")[.type] as? FileAttributeType == .typeDirectory)
    let mtime = try #require(attributes("hello.txt")[.modificationDate] as? Date)
    #expect(Int(mtime.timeIntervalSince1970) == 1_793_949_863)

    guard hardLinks else { return }
    let original = try #require(attributes("hello.txt")[.systemFileNumber] as? Int)
    let link = try #require(attributes("dir/hardlink.txt")[.systemFileNumber] as? Int)
    #expect(original == link)
}

@Suite struct AppleArchiveTests {
    #if canImport(Compression)
    static let variants = ["lzma", "lzfse", "zlib", "lz4", "lzbitmap", "none", "padded-murmur"]
    #else
    static let variants = ["lzma", "none", "padded-murmur"]
    #endif

    @Test(arguments: variants)
    func extractsFixture(variant: String) async throws {
        let archive = try AEAArchive(path: fixture("small-\(variant).aea"), options: fixtureOptions)
        #expect(archive.rootHeader.segmentSize == 16 << 10)
        try await withTemporaryDirectory { dir in
            try await archive.extract(to: FilePath(dir.path))
            try checkSmallTree(at: dir)
        }
    }

    @Test func decodesToRawArchive() async throws {
        let archive = try AEAArchive(path: fixture("small-lzma.aea"), options: fixtureOptions)
        try await withTemporaryDirectory { dir in
            let out = dir.appending(path: "out.aar")
            try await archive.decode(to: FilePath(out.path))
            #expect(try Data(contentsOf: out) == Data(contentsOf: fixtures.appending(path: "small.aar")))
        }
    }

    @Test func extractsRawArchive() async throws {
        try await withTemporaryDirectory { dir in
            try AppleArchiveExtractor.extract(archive: fixture("small.aar"), to: FilePath(dir.path))
            try checkSmallTree(at: dir)
        }
    }

    @Test func extractsMultipleClusters() async throws {
        let archive = try AEAArchive(
            path: fixture("multicluster.aea"),
            options: .init(signingKey: .publicKey(fixtureKey), maxConcurrentSegments: 3)
        )
        let segments = archive.rootHeader.rawSize / UInt64(archive.rootHeader.segmentSize)
        #expect(segments > UInt64(archive.rootHeader.segmentsPerCluster))

        var reports: [AEAProgress] = []
        try await withTemporaryDirectory { dir in
            try await archive.extract(to: FilePath(dir.path), progress: { reports.append($0) })
            let big = try Data(contentsOf: dir.appending(path: "big.bin"))
            #expect(big == Data((0..<270).flatMap { Array(String(format: "%08d", $0).utf8).repeated(2048) }))
            // the multi-cluster fixture was copied without preserving hard links
            try checkSmallTree(at: dir, hardLinks: false)
        }
        #expect(reports.first?.completedBytes == 0)
        #expect(reports.last?.fractionCompleted == 1)
        #expect(zip(reports, reports.dropFirst()).allSatisfy { $0.completedBytes < $1.completedBytes })
    }

    @Test func filtersEntries() async throws {
        let archive = try AEAArchive(path: fixture("small-lzma.aea"), options: fixtureOptions)
        try await withTemporaryDirectory { dir in
            try await archive.extract(to: FilePath(dir.path), filter: { $0 == "dir/run.sh" })
            let fm = FileManager.default
            #expect(fm.fileExists(atPath: dir.appending(path: "dir/run.sh").path))
            #expect(!fm.fileExists(atPath: dir.appending(path: "hello.txt").path))
            #expect(!fm.fileExists(atPath: dir.appending(path: "dir/sub").path))
        }
    }

    @Test func supportsCancellation() async throws {
        let archive = try AEAArchive(path: fixture("multicluster.aea"), options: fixtureOptions)
        let task = Task {
            var chunks = 0
            try await archive.decode { _ in
                chunks += 1
                if chunks == 5 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            return chunks
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func rejectsWrongSigningKey() throws {
        let other = P256.Signing.PrivateKey().publicKey
        #expect(throws: AEAError.self) {
            _ = try AEAArchive(path: fixture("small-lzma.aea"), options: .init(signingKey: .publicKey(other)))
        }
    }

    @Test func readsEmbeddedSigningKey() throws {
        // the auth data of Xcode_27.3_beta.aea
        let pem = try Data(contentsOf: fixtures.appending(path: "xcode-27.3-beta-chain.pem"))
        var authData = Data()
        let entry = Data(AEAArchive.certificateChainKey.utf8) + [0] + pem
        authData.appendLE(UInt32(4 + entry.count))
        authData.append(entry)
        let key = try AEAArchive.embeddedSigningKey(authData: authData)
        #expect(key.x963Representation == Data(hex:
            "0462656520562A5A7EC6E277DDD29A6735E54FA102A0C68FDB679C04EC5B216B"
            + "F59AF739BD06B23732ACB347B59A22AA6FE142337E00161AD8D13CFB80DC72F084"
        ))
    }

    @Test func requiresCertificateChainByDefault() async throws {
        await #expect(throws: AEAError.self) {
            try await withTemporaryDirectory { dir in
                try await AEAExtractor.liveValue.extract(fixture("small-lzma.aea"), to: FilePath(dir.path))
            }
        }
    }

    // offsets of the signature, root header, cluster header, and the last segment byte
    @Test(arguments: [22, 239, 317, -1])
    func rejectsCorruption(offset: Int) async throws {
        var data = try Data(contentsOf: fixtures.appending(path: "small-lzma.aea"))
        let index = offset < 0 ? data.count + offset : offset
        data[index] ^= 0x01
        try await withTemporaryDirectory { dir in
            let path = dir.appending(path: "corrupt.aea")
            try data.write(to: path)
            await #expect(throws: AEAError.self) {
                let archive = try AEAArchive(path: FilePath(path.path), options: fixtureOptions)
                try await archive.decode { _ in }
            }
        }
    }

    @Test func rejectsPathTraversal() throws {
        #expect(throws: AEAError.self) { try AppleArchiveExtractor.sanitize("../evil") }
        #expect(throws: AEAError.self) { try AppleArchiveExtractor.sanitize("a/../../evil") }
        #expect(throws: AEAError.self) { try AppleArchiveExtractor.sanitize("/etc/passwd") }
        #expect(try AppleArchiveExtractor.sanitize("./a//b/./c") == "a/b/c")
    }

    @Test func rejectsWritesThroughSymlinks() async throws {
        try await withTemporaryDirectory { dir in
            let extractor = try AppleArchiveExtractor(destination: FilePath(dir.appending(path: "out").path))
            func entry(_ type: Character, _ path: String, link: String? = nil) -> AppleArchiveHeader {
                var fields: [(key: AppleArchiveHeader.Key, value: AppleArchiveHeader.Value)] = [
                    (.type, .uint(UInt64(type.asciiValue!))),
                    (.path, .string(Data(path.utf8))),
                ]
                if let link { fields.append((.linkPath, .string(Data(link.utf8)))) }
                return AppleArchiveHeader(fields: fields)
            }
            try extractor.handle(.header(entry("L", "escape", link: dir.path)))
            try extractor.handle(.endOfEntry)
            #expect(throws: AEAError.self) {
                try extractor.handle(.header(entry("F", "escape/pwned")))
            }
            #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "pwned").path))
        }
    }
}

/// Extracts a real Xcode `.aea`. Set `XTL_TEST_XCODE_AEA` to its path to run.
@Test(.enabled(if: ProcessInfo.processInfo.environment["XTL_TEST_XCODE_AEA"] != nil))
func extractsXcodeAEA() async throws {
    let environment = ProcessInfo.processInfo.environment
    let path = try #require(environment["XTL_TEST_XCODE_AEA"])
    let output = environment["XTL_TEST_XCODE_AEA_OUTPUT"].map { URL(filePath: $0) }
        ?? FileManager.default.temporaryDirectory.appending(path: "xtool-xcode-aea-\(UUID().uuidString)")
    defer {
        if environment["XTL_TEST_XCODE_AEA_OUTPUT"] == nil {
            try? FileManager.default.removeItem(at: output)
        }
    }

    let start = Date()
    let lastPercent = LockIsolated(-1)
    try await AEAExtractor.liveValue.extract(FilePath(path), to: FilePath(output.path)) { fraction in
        let percent = Int(fraction * 100)
        lastPercent.withValue {
            guard percent != $0 else { return }
            $0 = percent
            print("[Extracting AEA] \(percent)%")
        }
    }
    print("Extracted in \(Date().timeIntervalSince(start))s")
    #expect(lastPercent.value == 100)

    let apps = try FileManager.default.contentsOfDirectory(atPath: output.path).filter { $0.hasSuffix(".app") }
    let app = try #require(apps.first)
    let plist = try Data(contentsOf: output.appending(path: "\(app)/Contents/Info.plist"))
    let info = try #require(try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
    #expect(info["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode")
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}

extension Array {
    fileprivate func repeated(_ count: Int) -> [Element] {
        Array([[Element]](repeating: self, count: count).joined())
    }
}
