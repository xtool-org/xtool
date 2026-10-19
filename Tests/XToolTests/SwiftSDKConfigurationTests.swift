import Foundation
import Testing
@testable import PackLib

struct SwiftSDKConfigurationTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func metadata(in bundle: URL) throws -> URL {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for path in ["Developer/SDKs/MacOSX.sdk", "swift_static", "include", "lib"] {
            let directory = bundle.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(path.utf8).write(to: directory.appendingPathComponent("marker.txt"))
        }
        let metadata = bundle.appendingPathComponent("swift-sdk.json")
        try Data(#"{"schemaVersion":"1.0","rootPath":"tools/bin"}"#.utf8)
            .write(to: bundle.appendingPathComponent("toolset.json"))
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": "4.0", "targetTriples": [
                "arm64-apple-macosx": [
                    "sdkRootPath": "Developer/SDKs/MacOSX.sdk",
                    "swiftResourcesPath": "/absolute/swift",
                    "swiftStaticResourcesPath": "swift_static",
                    "includeSearchPaths": ["include"],
                    "librarySearchPaths": ["lib"],
                    "toolsetPaths": ["toolset.json"],
                ],
                "arm64-apple-ios": ["sdkRootPath": "Developer/SDKs/iPhoneOS.sdk"],
            ],
        ]).write(to: metadata)
        return metadata
    }

    @Test func dependencyInspectionKeepsTheRootPackagesSDKCache() async throws {
        // The planner inspects each dependency through a copy rebased onto its directory.
        let settings = try await BuildSettings(configuration: .release, triple: "arm64-apple-macosx15.0",
                                               packagePath: "/work/App")
        let dependency = settings.withPackagePath("/work/App/.build/checkouts/Dependency")
        #expect(dependency.swiftSDKCacheDirectory.path == "/work/App/.build/xtool-sdk")
    }

    @Test func destinationSelectsOneTargetAndPreservesSDKPathsWithoutChangingInstallation() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("darwin.artifactbundle", isDirectory: true)
        let original = try metadata(in: bundle)
        let before = try Data(contentsOf: original)
        let target = try TargetTriple("arm64-apple-macosx16.0")
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let destination = try SwiftSDKConfiguration.destination(in: directory, for: target, cacheDirectory: cache)
        let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination.url)) as? [String: Any])
        let triples = try #require(document["targetTriples"] as? [String: [String: Any]])
        #expect(Set(triples.keys) == ["arm64-apple-macosx"])
        let properties = try #require(triples["arm64-apple-macosx"])
        #expect(properties["swiftResourcesPath"] as? String == "/absolute/swift")
        for (key, marker) in [("sdkRootPath", "Developer/SDKs/MacOSX.sdk"), ("swiftStaticResourcesPath", "swift_static")] {
            let path = try #require(properties[key] as? String)
            #expect((path as NSString).isAbsolutePath)
            #expect(try String(contentsOfFile: path + "/marker.txt", encoding: .utf8) == marker)
        }
        for (key, marker) in [("includeSearchPaths", "include"), ("librarySearchPaths", "lib")] {
            let paths = try #require(properties[key] as? [String])
            #expect(paths.count == 1)
            let path = try #require(paths.first)
            #expect((path as NSString).isAbsolutePath)
            #expect(try String(contentsOfFile: path + "/marker.txt", encoding: .utf8) == marker)
        }
        #expect(properties["toolsetPaths"] as? [String] == [bundle.appendingPathComponent("toolset.json").path])
        #expect(destination.toolSearchPaths == [bundle.appendingPathComponent("tools/bin").path])
        #expect(try Data(contentsOf: original) == before)
        #expect(try SwiftSDKConfiguration.destination(in: directory, for: target, cacheDirectory: cache) == destination)
    }

    @Test func missingAndAmbiguousSDKsFailWithoutPublishingConfiguration() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = try TargetTriple("arm64-apple-macosx15.0")
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        #expect(throws: (any Error).self) {
            try SwiftSDKConfiguration.destination(in: directory, for: target, cacheDirectory: cache)
        }
        _ = try metadata(in: directory.appendingPathComponent("first.artifactbundle", isDirectory: true))
        _ = try metadata(in: directory.appendingPathComponent("second.artifactbundle", isDirectory: true))
        #expect(throws: (any Error).self) {
            try SwiftSDKConfiguration.destination(in: directory, for: target, cacheDirectory: cache)
        }
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }
}
