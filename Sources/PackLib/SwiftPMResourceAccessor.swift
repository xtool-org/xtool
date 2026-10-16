import Foundation
import XUtils

/// Native SwiftPM generates bundle-root lookup, which requires unsigned root aliases on macOS.
/// Compile an adapted view of those generated sources; keep package sources and build fallbacks intact.
enum SwiftPMResourceAccessor {
    struct Overlay {
        var url: URL
        /// Generated accessors whose adapted copy changed while writing this overlay.
        /// Modules compiled from them before used a stale or missing adaptation.
        var changedSources: [URL]
    }

    static func bundleNames(for products: [Plan.Product]) -> Set<String> {
        Set(products.filter { $0.platform == .macOS }.flatMap(\.resources).compactMap { resource -> String? in
            guard case .bundle(let package, let target) = resource else { return nil }
            return "\(package)_\(target).bundle"
        })
    }

    /// One overlay covers every product: a resource target can live in a library that several products share.
    ///
    /// The overlay path never changes, so compiler flags stay stable across builds. Before a build,
    /// pass `requireAll: false` to cover the accessors an earlier build generated; after it, pass
    /// `requireAll: true` and recompile whatever `changedSources` lists.
    static func overlay(
        for products: [Plan.Product], in directory: URL, output: URL, requireAll: Bool = true
    ) throws -> Overlay? {
        let names = bundleNames(for: products)
        guard !names.isEmpty else { return nil }
        let manager = FileManager.default
        // Keep the backend's spelling (not Foundation's canonicalized /private/var spelling):
        // VFS names must match the compiler's source arguments exactly.
        let entries = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        let candidates = entries
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
        if requireAll && matched != names {
            throw StringError("Missing supported generated SwiftPM resource accessor for: "
                              + names.subtracting(matched).sorted().joined(separator: ", ")
                              + "; macOS bundles currently require Swift resource targets")
        }
        let destination = output.appendingPathComponent("resource-accessors")
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        var roots: [[String: String]] = []
        var changed: [URL] = []
        for (source, contents) in files {
            // Name copies after their module's build directory, which is unique within the bin directory.
            let name = source.deletingLastPathComponent().deletingLastPathComponent().deletingPathExtension()
            let copy = destination.appendingPathComponent("\(name.lastPathComponent).swift")
            if try Data(contents.utf8).writeIfChanged(to: copy) { changed.append(source) }
            roots.append(["type": "file", "name": source.path, "external-contents": copy.path])
        }
        let overlay = destination.appendingPathComponent("overlay.json")
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 0, "use-external-names": false, "roots": roots,
        ], options: [.sortedKeys])
        try data.writeIfChanged(to: overlay)
        return Overlay(url: overlay, changedSources: changed)
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
