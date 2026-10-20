import Foundation
import XUtils

enum SwiftSDKConfiguration {
    struct Destination: Equatable {
        let url: URL
        let toolSearchPaths: [String]
    }

    /// SwiftPM's bundle selector requires an exact target triple. A single-target
    /// destination lets it apply the requested deployment version after decoding.
    static func destination(in directory: URL, for target: TargetTriple, cacheDirectory: URL) throws -> Destination {
        let identity = target.sdkIdentity
        let bundles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "artifactbundle" }
        var matches: [[String: Any]] = []
        for bundle in bundles {
            let metadata = bundle.appendingPathComponent("swift-sdk.json")
            guard FileManager.default.fileExists(atPath: metadata.path) else { continue }
            let data = try Data(contentsOf: metadata)
            guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let triples = document["targetTriples"] as? [String: [String: Any]],
                  var properties = triples[identity] else { continue }
            for key in ["sdkRootPath", "swiftResourcesPath", "swiftStaticResourcesPath"] {
                if let path = properties[key] as? String {
                    properties[key] = URL(fileURLWithPath: path, relativeTo: bundle).standardizedFileURL.path
                }
            }
            for key in ["includeSearchPaths", "librarySearchPaths", "toolsetPaths"] {
                if let paths = properties[key] as? [String] {
                    properties[key] = paths.map { URL(fileURLWithPath: $0, relativeTo: bundle).standardizedFileURL.path }
                }
            }
            matches.append(properties)
        }
        guard matches.count == 1, let properties = matches.first else {
            throw StringError("Expected one Swift SDK for '\(identity)' in '\(directory.path)'; found \(matches.count)")
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": "4.0", "targetTriples": [identity: properties],
        ], options: [.sortedKeys])
        let hash = ArtifactInventory.hash(data: data)
        var toolSearchPaths: [String] = []
        for path in properties["toolsetPaths"] as? [String] ?? [] {
            let toolset = URL(fileURLWithPath: path)
            let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: toolset)) as? [String: Any]
            if let root = contents?["rootPath"] as? String {
                toolSearchPaths.append(URL(fileURLWithPath: root, relativeTo: toolset).standardizedFileURL.path)
            }
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let destination = cacheDirectory.appendingPathComponent("\(identity)-\(hash).json")
        if !FileManager.default.fileExists(atPath: destination.path) { try data.write(to: destination, options: .atomic) }
        return Destination(url: destination, toolSearchPaths: toolSearchPaths)
    }
}
