import Foundation
import XUtils

/// Native SwiftPM generates bundle-root lookup, which requires unsigned root aliases on macOS.
/// Compile an adapted view of those generated sources; keep package sources and build fallbacks intact.
enum SwiftPMResourceAccessor {
    /// One overlay covers every product: a resource target can live in a library that several products share.
    static func overlay(for products: [Plan.Product], in directory: URL, output: URL) throws -> URL? {
        let names = Set(products.filter { $0.platform == .macOS }.flatMap(\.resources).compactMap { resource -> String? in
            guard case .bundle(let package, let target) = resource else { return nil }
            return "\(package)_\(target).bundle"
        })
        guard !names.isEmpty else { return nil }
        let manager = FileManager.default
        // Keep the backend's spelling (not Foundation's canonicalized /private/var spelling):
        // VFS names must match the compiler's source arguments exactly.
        let candidates = try manager.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".build") && !$0.hasSuffix("-tool.build") }
            .map { directory.appendingPathComponent($0) }
            .map { $0.appendingPathComponent("DerivedSources/resource_bundle_accessor.swift") }
            .filter { manager.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
        var matched: Set<String> = []
        var files: [(URL, String)] = []
        for candidate in candidates {
            let source = try String(contentsOf: candidate, encoding: .utf8)
            for name in names where source.contains("appendingPathComponent(\(String(reflecting: name)))") {
                guard matched.insert(name).inserted else {
                    throw StringError("Ambiguous generated SwiftPM accessor for '\(name)'")
                }
                files.append((candidate, try adapted(source, bundleName: name)))
            }
        }
        guard matched == names else {
            throw StringError("Missing supported generated SwiftPM resource accessor for: "
                              + names.subtracting(matched).sorted().joined(separator: ", ")
                              + "; macOS bundles currently require Swift resource targets")
        }
        let destination = output.appendingPathComponent("resource-accessors")
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        var roots: [[String: String]] = []
        for (index, file) in files.enumerated() {
            let copy = destination.appendingPathComponent("\(index).swift")
            try Data(file.1.utf8).write(to: copy, options: .atomic)
            roots.append(["type": "file", "name": file.0.path, "external-contents": copy.path])
        }
        let overlay = destination.appendingPathComponent("overlay.json")
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 0, "use-external-names": false, "roots": roots,
        ], options: [.sortedKeys])
        try data.write(to: overlay, options: .atomic)
        return overlay
    }

    static func adapted(_ source: String, bundleName: String) throws -> String {
        let lookup = "let mainPath = Bundle.main.bundleURL.appendingPathComponent(\(String(reflecting: bundleName))).path"
        guard source.contains("extension Foundation.Bundle {"),
              source.components(separatedBy: lookup).count == 2,
              source.components(separatedBy: "Bundle(path: mainPath)").count == 2 else {
            throw StringError("Unsupported generated SwiftPM resource accessor for '\(bundleName)'")
        }
        let replacement = lookup.replacingOccurrences(of: "Bundle.main.bundleURL",
                                                      with: "(Bundle.main.resourceURL ?? Bundle.main.bundleURL)")
        // Keep directory-based helper lookup too. All products need the same accessor because a
        // resource target can live in a dylib shared by app, services, and helpers in one build tree.
        let fallback = "Bundle(path: mainPath) ?? Bundle(url: Bundle.main.bundleURL.appendingPathComponent("
            + String(reflecting: bundleName) + "))"
        return source.replacingOccurrences(of: lookup, with: replacement)
            .replacingOccurrences(of: "Bundle(path: mainPath)", with: fallback)
    }
}
