import CustomDump
import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing
import XKit
import X509
@testable import XToolSupport

@Suite(.dependency(\.signer, DependencyValues.live.signer))
struct CodesignToolTests {
    @Dependency(\.signer) private var signer

    @Test func signerUsesCertificateIdentity() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "Executable")
        try machO().write(to: path)
        // Use the same RSA key representation as provisioning, with a temporary
        // self-signed certificate so this test needs no developer account.
        let key = try Keypair().privateKey()
        let privateKey = try X509.Certificate.PrivateKey(pemEncoded: String(decoding: key.data, as: UTF8.self))
        let name = try DistinguishedName { CommonName("xtool signing tests") }
        let now = Date()
        let certificate = try XKit.Certificate(raw: X509.Certificate(
            version: .v3,
            serialNumber: .init(bytes: [1]),
            publicKey: privateKey.publicKey,
            notValidBefore: now,
            notValidAfter: now + 3600,
            issuer: name,
            subject: name,
            signatureAlgorithm: .sha256WithRSAEncryption,
            extensions: .init(),
            issuerPrivateKey: privateKey
        ))
        let progress = LockIsolated<[Double?]>([])
        try await signer.sign(app: path, identity: .real(certificate, key), entitlementMapping: [:], deep: true) { value in
            progress.withValue { $0.append(value) }
        }
        expectNoDifference(progress.value, [nil])
        let slots = try signatureSlots(at: path)
        let directory = try #require(slots[0])
        #expect(read32(directory, 12) & 2 == 0) // Not CS_ADHOC.
        let cms = try #require(slots[0x10000])
        #expect(cms.count > 8) // The CMS wrapper must contain a signature.
    }

    @Test func signerUsesEachBundlesProvisionedEntitlements() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "App.app")
        let child = app.appending(path: "PlugIns/Child.appex")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        var mapping: [URL: Data] = [:]
        for bundle in [app, child] {
            try machO().write(to: bundle.appending(path: "Executable"))
            try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "org.example.\(bundle.deletingPathExtension().lastPathComponent)",
                "CFBundleExecutable": "Executable", "CFBundleVersion": "1",
            ], format: .xml, options: 0).write(to: bundle.appending(path: "Info.plist"))
            let xml = try PropertyListSerialization.data(
                fromPropertyList: ["example": bundle.lastPathComponent], format: .xml, options: 0
            )
            mapping[bundle] = xml
        }
        try await signer.sign(app: app, identity: .adhoc, entitlementMapping: mapping, deep: true, progress: { _ in })
        for bundle in [app, child] {
            let data = try await signer.analyze(executable: bundle.appending(path: "Executable"))
            let xml = try #require(data)
            let value = try PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: String]
            expectNoDifference(value, ["example": bundle.lastPathComponent])
        }
    }

    @Test func signerRejectsEntitlementsOutsideTheApp() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "App.app")
        let sibling = root.appending(path: "App.app-copy")
        // Keep the signing input valid so any error must come from the invalid
        // entitlement scope, rather than a missing executable or bundle metadata.
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let executable = app.appending(path: "Executable")
        let original = machO()
        try original.write(to: executable)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "org.example.App",
            "CFBundleExecutable": "Executable", "CFBundleVersion": "1",
        ], format: .xml, options: 0).write(to: app.appending(path: "Info.plist"))
        let entitlements = try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
        await #expect(throws: (any Error).self) {
            try await signer.sign(
                app: app, identity: .adhoc, entitlementMapping: [sibling: entitlements], deep: true, progress: { _ in }
            )
        }
        expectNoDifference(try Data(contentsOf: executable), original)
    }

    @Test func signsCodeAndGeneratesDERForExecutables() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let entitlements = try PropertyListSerialization.data(
            fromPropertyList: ["get-task-allow": true, "example": "<&>\t\n🍎 &lt;"], format: .binary, options: 0
        )
        try entitlements.write(to: root.appending(path: "entitlements.plist"))
        for (name, type): (String, UInt32) in [("Executable", 2), ("Library", 6)] {
            let path = root.appending(path: name)
            try machO(fileType: type).write(to: path)
            try await sign(["--entitlements", "entitlements.plist", "--generate-entitlement-der", name], in: root)
            let slots = try signatureSlots(at: path)
            let directory = try #require(slots[0])
            expectNoDifference(read32(directory, 12), 2) // CS_ADHOC
            let xml = Data(try #require(slots[5]).dropFirst(8))
            #expect(xml.starts(with: Data("<?xml".utf8)))
            expectNoDifference(try DerqEncoder().encodeEntitlements(xml),
                               try DerqEncoder().encodeEntitlements(entitlements))
            // RCodesign embeds XML for both file types, but only executables
            // receive a DER entitlement slot.
            if type == 2 {
                expectNoDifference(Data(try #require(slots[7]).dropFirst(8)),
                                   try DerqEncoder().encodeEntitlements(entitlements))
            } else {
                #expect(slots[7] == nil)
            }
        }
    }

    @Test func convertsXMLReferencesAndPreservesLegacyEntitlements() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "Executable")
        try machO().write(to: path)
        let xml = Data(("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>"
                        + "<key>a&amp;b</key><string>&lt;&gt;&amp;&quot;&apos; &amp;lt;"
                        + "&#9;&#10;&#13;&#x1F34E;&#128578;\t\r\n</string></dict></plist>").utf8)
        try await signer.sign(app: path, identity: .adhoc, entitlementMapping: [path: xml], deep: false, progress: { _ in })
        var slots = try signatureSlots(at: path)
        let expected = try DerqEncoder().encodeEntitlements(xml)
        expectNoDifference(Data(try #require(slots[7]).dropFirst(8)), expected)

        // Model an older signature with only the XML slot. Re-signing must add
        // matching DER without changing the existing XML entitlement bytes.
        slots.removeValue(forKey: 7)
        var signature = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { signature.append(contentsOf: $0) } }
        let headerSize = 12 + slots.count * 8
        append32(0xfade0cc0)
        append32(UInt32(headerSize + slots.values.reduce(0) { $0 + $1.count }))
        append32(UInt32(slots.count))
        var offset = headerSize
        let ordered = slots.sorted { $0.key < $1.key }
        for (type, slot) in ordered {
            append32(type)
            append32(UInt32(offset))
            offset += slot.count
        }
        for (_, slot) in ordered { signature.append(slot) }
        var contents = try Data(contentsOf: path)
        contents.replaceSubrange(4096..<(4096 + signature.count), with: signature)
        try contents.write(to: path)
        try await sign(["--preserve-metadata=identifier,entitlements,flags", "Executable"], in: root)
        let preserved = try signatureSlots(at: path)
        expectNoDifference(preserved[5], slots[5])
        expectNoDifference(Data(try #require(preserved[7]).dropFirst(8)), expected)
    }

    @Test func preservesCopiedProductMetadata() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "Original")
        try machO().write(to: original)
        try PropertyListSerialization.data(fromPropertyList: ["get-task-allow": true], format: .xml, options: 0)
            .write(to: root.appending(path: "entitlements.plist"))
        try await sign(["--entitlements", "entitlements.plist", "Original"], in: root)
        let originalSlots = try signatureSlots(at: original)
        var contents = try Data(contentsOf: original)
        // Give the source a restrict flag to ensure re-signing reads metadata
        // instead of simply deriving a new identifier and resetting all flags.
        let directoryOffset = Int(read32(contents, 4096 + 16))
        contents.replaceSubrange((4096 + directoryOffset + 12)..<(4096 + directoryOffset + 16),
                                 with: [0, 0, 8, 2]) // CS_RESTRICT | CS_ADHOC
        let copy = root.appending(path: "Copied")
        try contents.write(to: copy)
        try await sign(["--preserve-metadata=identifier,entitlements,flags", "Copied"], in: root)
        let slots = try signatureSlots(at: copy)
        let directory = try #require(slots[0])
        let identifierOffset = Int(read32(directory, 20))
        expectNoDifference(String(decoding: directory.dropFirst(identifierOffset).prefix { $0 != 0 }, as: UTF8.self),
                           "Original")
        expectNoDifference(read32(directory, 12), 0x802)
        expectNoDifference(slots[5], originalSlots[5])
        expectNoDifference(slots[7], originalSlots[7])
        // Explicit entitlements take precedence over preserved entitlements.
        let empty = try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
        try empty.write(to: root.appending(path: "empty.plist"))
        try await sign(["--preserve-metadata=identifier,entitlements,flags",
                        "--entitlements", "empty.plist", "Copied"], in: root)
        let replaced = try signatureSlots(at: copy)
        expectNoDifference(Data(try #require(replaced[7]).dropFirst(8)), try DerqEncoder().encodeEntitlements(empty))
    }

    @Test func clearsUnrequestedEntitlementsWhenResigning() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "Executable")
        try machO().write(to: executable)
        let entitlements = try PropertyListSerialization.data(
            fromPropertyList: ["application-identifier": "org.example.App"], format: .xml, options: 0
        )
        try entitlements.write(to: root.appending(path: "entitlements.plist"))
        let empty = try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
        let emptyDER = try DerqEncoder().encodeEntitlements(empty)
        for arguments in [[], ["--preserve-metadata=identifier,flags"]] {
            try await sign(["--entitlements", "entitlements.plist", "Executable"], in: root)
            // Model an incremental build that no longer supplies --entitlements,
            // without relinking or otherwise removing the previous signature.
            try await sign(arguments + ["Executable"], in: root)
            let slots = try signatureSlots(at: executable)
            let xml = Data(try #require(slots[5]).dropFirst(8))
            expectNoDifference(try DerqEncoder().encodeEntitlements(xml), emptyDER)
            expectNoDifference(Data(try #require(slots[7]).dropFirst(8)), emptyDER)
        }
    }

    @Test func signingParentDoesNotModifyNestedCode() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "App.app")
        let child = app.appending(path: "PlugIns/Child.appex")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        for bundle in [app, child] {
            try machO().write(to: bundle.appending(path: "Executable"))
            try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "org.example.\(bundle.deletingPathExtension().lastPathComponent)",
                "CFBundleExecutable": "Executable", "CFBundleVersion": "1",
            ], format: .xml, options: 0).write(to: bundle.appending(path: "Info.plist"))
        }
        try await sign([child.path], in: root)
        let childExecutable = try Data(contentsOf: child.appending(path: "Executable"))
        let childSeal = try Data(contentsOf: child.appending(path: "_CodeSignature/CodeResources"))
        try await sign([app.path], in: root)
        expectNoDifference(try Data(contentsOf: child.appending(path: "Executable")), childExecutable)
        expectNoDifference(try Data(contentsOf: child.appending(path: "_CodeSignature/CodeResources")), childSeal)
        #expect(FileManager.default.fileExists(atPath: app.appending(path: "_CodeSignature/CodeResources").path))
        let slots = try signatureSlots(at: app.appending(path: "Executable"))
        let empty = try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
        let emptyDER = try DerqEncoder().encodeEntitlements(empty)
        expectNoDifference(try DerqEncoder().encodeEntitlements(Data(try #require(slots[5]).dropFirst(8))), emptyDER)
        expectNoDifference(Data(try #require(slots[7]).dropFirst(8)), emptyDER)
    }

    @Test func acceptsGeneratePreEncryptHashesFlag() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "Executable")
        try machO().write(to: path)

        try await sign([
            "--preserve-metadata=identifier,entitlements,flags",
            "--generate-entitlement-der",
            "--generate-pre-encrypt-hashes",
            path.path,
        ], in: root)
        let slots = try signatureSlots(at: path)
        #expect(!slots.isEmpty)
    }

    @Test func rejectsInvalidXMLBeforeSigning() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "Executable")
        let original = machO()
        try original.write(to: path)
        for value in ["&unknown;", "&amp", "&#;", "&#x;", "&#0;", "&#xD800;", "&#x110000;",
                      "&#9999999999999999999999999;", "&#-1;"] {
            try original.write(to: path)
            let xml = Data("<plist><dict><key>value</key><string>\(value)</string></dict></plist>".utf8)
            try xml.write(to: root.appending(path: "entitlements.plist"))
            let result = try await CodesignTool().execute(
                commandLine: ["codesign", "--force", "--sign", "-", "--entitlements", "entitlements.plist", path.path],
                workingDirectory: root.path, environment: [:]
            )
            guard case .result(.exit(let status), _, let stderr) = result else {
                Issue.record("Expected a tool exit status")
                continue
            }
            #expect(status != 0, "Invalid XML reference: \(value)")
            #expect(!stderr.isEmpty)
            expectNoDifference(try Data(contentsOf: path), original)
        }
    }

    @Test func rejectsUnsupportedOperationsBeforeChangingFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "Executable")
        let original = machO()
        try original.write(to: path)
        for arguments in [
            ["-r-", "--display"],
            ["-r", "-", "--display"],
            ["--requirements", "-", "--display"],
            ["--force", "--sign", "iPhone Developer"],
            ["--force", "--sign", "-", "--preserve-metadata=requirements"],
            ["--force", "--sign", "-", "--options", "runtime"],
        ] {
            let result = try await CodesignTool().execute(
                commandLine: ["codesign"] + arguments + [path.path], workingDirectory: root.path, environment: [:]
            )
            guard case .result(.exit(let status), _, let stderr) = result else {
                Issue.record("Expected a tool exit status")
                continue
            }
            #expect(status != 0)
            #expect(!stderr.isEmpty)
            if arguments.contains("--display") {
                #expect(String(decoding: stderr, as: UTF8.self).contains(
                    "Code requirement operations (-r/--requirements) are not supported yet"
                ))
            }
            expectNoDifference(try Data(contentsOf: path), original)
        }
    }

    private func sign(_ arguments: [String], in directory: URL) async throws {
        let result = try await CodesignTool().execute(
            commandLine: ["codesign", "--force", "--sign", "-", "--timestamp=none"] + arguments,
            workingDirectory: directory.path, environment: [:]
        )
        guard case .result(.exit(let status), _, let stderr) = result else {
            Issue.record("Expected a tool exit status")
            return
        }
        try #require(status == 0, "\(String(decoding: stderr, as: UTF8.self))")
    }

    private func temporaryDirectory() throws -> URL {
        var template = Array(FileManager.default.temporaryDirectory.appending(path: "xtool-codesign-XXXXXX").path.utf8CString)
        try #require(mkdtemp(&template) != nil)
        let path = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func read32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    private func signatureSlots(at path: URL) throws -> [UInt32: Data] {
        let data = try Data(contentsOf: path)
        let base = 4096
        try #require(read32(data, base) == 0xfade0cc0)
        var slots: [UInt32: Data] = [:]
        for index in 0..<Int(read32(data, base + 8)) {
            let type = read32(data, base + 12 + index * 8)
            let offset = base + Int(read32(data, base + 16 + index * 8))
            slots[type] = data.subdata(in: offset..<(offset + Int(read32(data, offset + 4))))
        }
        return slots
    }

    // A minimal unsigned arm64 Mach-O with room for a signature load command.
    // The signer appends the signature to the empty __LINKEDIT segment. These
    // tests do not execute it or require an SDK/compiler; they inspect the signed bytes.
    private func machO(fileType: UInt32 = 2) -> Data {
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        for value in [0xfeedfacf, 0x0100000c, 0, fileType, 2, 224, 0, 0] { append32(value) }
        for (name, offset, size): (String, UInt64, UInt64) in [("__TEXT", 0, 4096), ("__LINKEDIT", 4096, 0)] {
            let isText = name == "__TEXT"
            append32(0x19)
            append32(isText ? 152 : 72)
            data.append(contentsOf: name.utf8)
            data.append(Data(repeating: 0, count: 16 - name.utf8.count))
            for value in [0x100000000 + offset, size, offset, size] { append64(value) }
            for value: UInt32 in [5, 5, isText ? 1 : 0, 0] { append32(value) }
            if isText {
                // A real section lets the signer determine where header padding
                // ends before inserting LC_CODE_SIGNATURE. The sole instruction
                // is arm64 `ret`; the tests only inspect the file, never run it.
                for name in ["__text", "__TEXT"] {
                    data.append(contentsOf: name.utf8)
                    data.append(Data(repeating: 0, count: 16 - name.utf8.count))
                }
                append64(0x100000400)
                append64(4)
                for value: UInt32 in [1024, 2, 0, 0, 0x80000400, 0, 0, 0] { append32(value) }
            }
        }
        data.append(Data(repeating: 0, count: 4096 - data.count))
        data.replaceSubrange(1024..<1028, with: [0xc0, 0x03, 0x5f, 0xd6])
        return data
    }
}
