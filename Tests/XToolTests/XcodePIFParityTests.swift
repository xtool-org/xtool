import CustomDump
import Foundation
import Subprocess
import Testing
import XcodePIFConversion
import XcodeProjects
import XPIF
import XUtils
import Dependencies
@testable import XToolSupport

struct XcodePIFParityTests {
    #if os(macOS)
    @Test(.requiresXcode("27.2"), arguments: [
        "Features.xcodeproj",
        "Synchronized.xcodeproj",
        "App.xcodeproj",
        "PIF.xcworkspace",
        "Packages.xcodeproj",
        "DiscoveredPackages.xcodeproj",
    ])
    func matchesXcodebuild(fixture: String) async throws {
        let projects = fixtureURL("Projects")
        let url = projects.appending(path: fixture).resolvingSymlinksInPath()
        let temporary = try TemporaryDirectory(name: "PIFParity")
        let dump = temporary.url.appending(path: "xcode.json")
        let derivedData = temporary.url.appending(path: "DerivedData")
        let result = try await Subprocess.run(
            .path(.init(TestXcode.current().appending(path: "Contents/Developer/usr/bin/xcodebuild").path)),
            arguments: .init([
                url.pathExtension == "xcworkspace" ? "-workspace" : "-project", url.path,
                "-dumpPIF", dump.path,
                "-IDECustomDerivedDataLocation=\(derivedData.path)",
                "-IDEEnableNewPackagePIFBuilder=YES",
                "-IDEApplicationwideBuildSettings={}", "-PBXApplicationwideBuildSettings={}",
            ]),
            output: .string(limit: .max), error: .string(limit: .max)
        )
        try #require(result.terminationStatus.isSuccess, "\(result.standardOutput)\n\(result.standardError)")
        let builder = try url.pathExtension == "xcworkspace"
            ? XcodePIFBuilder(workspace: XcodeWorkspace(url: url))
            : XcodePIFBuilder(project: XcodeProject(url: url))
        let packages = try await withDependencies {
            $0.out.write = { _, _, _ in }
        } operation: {
            try await XcodePackagePIFBuilder(builder: builder, rootDirectory: URL(filePath: ".")).build()
        }
        let actual = try XPIF.Container(workspace: builder.build(packageProjects: packages)).data()
        let expected = try Data(contentsOf: dump)
        expectNoDifference(try canonicalJSON(expected), try canonicalJSON(actual))
        let roundTripped = try XPIF.Container(data: actual).data()
        expectNoDifference(try canonicalJSON(actual), try canonicalJSON(roundTripped))
    }
    #endif

    @Test func ignoresEnvelopeSignaturesAndResolvesTheirReferences() throws {
        let resigned = comparisonFixture.replacingOccurrences(of: "signature-", with: "resigned-")
        expectNoDifference(try canonicalJSON(Data(comparisonFixture.utf8)), try canonicalJSON(Data(resigned.utf8)))
    }

    @Test(arguments: [
        ("\"name\":\"App\"", "\"name\":\"Changed\""),
        ("\"expectedSignature\":\"signed-file\"", "\"expectedSignature\":\"changed\""),
        ("\"signature\":\"semantic-value\"", "\"signature\":\"changed\""),
        ("[\"signature-a\",\"signature-b\"]", "[\"signature-b\",\"signature-a\"]"),
        ("[\"signature-a\",\"signature-b\"]", "[\"signature-a\",\"signature-a\"]"),
        ("\"name\":\"App\"", "\"name\":\"App\",\"extra\":false"),
    ])
    func preservesNonSignatureDifferences(original: String, replacement: String) throws {
        let changed = comparisonFixture.replacingOccurrences(of: original, with: replacement)
        #expect(try canonicalJSON(Data(comparisonFixture.utf8)) != canonicalJSON(Data(changed.utf8)))
    }

    private var comparisonFixture: String {
        """
        [
          {"type":"workspace","signature":"signature-w","contents":{"guid":"w","projects":["signature-p"]}},
          {"type":"project","signature":"signature-p","contents":{"guid":"p","targets":["signature-a","signature-b"]}},
          {"type":"target","signature":"signature-a","contents":{"guid":"a","name":"App",
            "expectedSignature":"signed-file","buildSettings":{"signature":"semantic-value"}}},
          {"type":"target","signature":"signature-b","contents":{"guid":"b","name":"Library"}}
        ]
        """
    }

    /// Compare raw JSON, so decoding through XPIF cannot hide missing or extra fields.
    /// Signature references are replaced with GUIDs, preserving graph membership and order.
    private func canonicalJSON(_ data: Data) throws -> String {
        var objects = try JSONDecoder().decode([[String: XPIF.JSONValue]].self, from: data)
        var signatures: [XPIF.JSONValue: XPIF.JSONValue] = [:]
        for object in objects {
            let signature = try #require(object["signature"])
            guard case .object(let contents) = object["contents"] else {
                throw ParityError.invalidContents
            }
            let guid = try #require(contents["guid"])
            try #require(signatures.updateValue(guid, forKey: signature) == nil, "Duplicate signature")
        }
        for index in objects.indices {
            objects[index].removeValue(forKey: "signature")
            guard case .object(var contents) = objects[index]["contents"] else {
                throw ParityError.invalidContents
            }
            let key: String?
            switch objects[index]["type"] {
            case .string("workspace"): key = "projects"
            case .string("project"): key = "targets"
            default: key = nil
            }
            if let key {
                guard case .array(let references) = contents[key] else { throw ParityError.invalidContents }
                contents[key] = .array(try references.map { try #require(signatures[$0], "Dangling signature reference") })
            }
            objects[index]["contents"] = .object(contents)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(objects), as: UTF8.self)
    }

    private enum ParityError: Error {
        case invalidContents
    }
}
