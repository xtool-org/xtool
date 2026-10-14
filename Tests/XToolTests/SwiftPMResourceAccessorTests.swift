import Dependencies
import Foundation
import Testing
@testable import PackLib

struct SwiftPMResourceAccessorTests {
    private let bundleName = "Package_Resources.bundle"

    private var generatedSource: String {
        """
        import Foundation
        extension Foundation.Bundle {
            static nonisolated let module: Bundle = {
                let mainPath = Bundle.main.bundleURL.appendingPathComponent("Package_Resources.bundle").path
                let buildPath = "/build/Package_Resources.bundle"
                return Bundle(path: mainPath) ?? Bundle(path: buildPath)!
            }()
        }
        """
    }

    private func product(platform: String = "macosx", kind: Plan.ProductType = .application) throws -> Plan.Product {
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-\(platform)15.0")
        return Plan.Product(target: target, type: kind, product: "App", bundleID: "test.App", infoPlist: [:],
                            resources: [.bundle(package: "Package", target: "Resources")])
    }

    @Test func adaptsOnlyGeneratedMainLookupAndRetainsBuildFallback() throws {
        let result = try SwiftPMResourceAccessor.adapted(generatedSource, bundleName: bundleName)
        #expect(result.contains("(Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent"))
        #expect(result.contains("let buildPath = \"/build/Package_Resources.bundle\""))
        #expect(result.contains("static nonisolated let module: Bundle"))
        #expect(result.contains("Bundle(url: Bundle.main.bundleURL.appendingPathComponent(\"Package_Resources.bundle\"))"))
        #expect(result.contains("?? Bundle(path: buildPath)!"))
    }

    @Test(arguments: ["", "extension Foundation.Bundle {}", "let mainPath = Bundle.main.bundleURL"])
    func unknownGeneratedSourceRejects(source: String) {
        #expect(throws: (any Error).self) {
            try SwiftPMResourceAccessor.adapted(source, bundleName: bundleName)
        }
    }

    @Test func overlayOwnsCopiesAndLeavesGeneratedAndHostSourcesUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let sources = ["Resources.build", "Resources-tool.build"].map {
            root.appendingPathComponent("\($0)/DerivedSources/resource_bundle_accessor.swift")
        }
        for source in sources {
            try manager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(generatedSource.utf8).write(to: source)
        }
        let prepared = try SwiftPMResourceAccessor.overlay(for: [product()], in: root, output: root.appendingPathComponent("owned"))
        let overlay = try #require(prepared)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: overlay)) as? [String: Any])
        #expect(json["use-external-names"] as? Bool == false)
        let roots = try #require(json["roots"] as? [[String: String]])
        #expect(roots.count == 1)
        #expect(roots.first?["name"] == sources[0].path)
        let copy = URL(fileURLWithPath: try #require(roots.first?["external-contents"]))
        #expect(try String(contentsOf: copy, encoding: .utf8).contains("Bundle.main.resourceURL"))
        for source in sources {
            #expect(try String(contentsOf: source, encoding: .utf8) == generatedSource)
        }
        // Repeated preparation stays deterministic and supports incremental/retry builds.
        let first = try Data(contentsOf: overlay)
        _ = try SwiftPMResourceAccessor.overlay(for: [product()], in: root, output: root.appendingPathComponent("owned"))
        #expect(try Data(contentsOf: overlay) == first)
    }

    @Test func iosKeepsNativeAccessors() throws {
        let missing = URL(fileURLWithPath: "/does-not-exist")
        #expect(try SwiftPMResourceAccessor.overlay(for: [product(platform: "ios")], in: missing, output: missing) == nil)
    }

    @Test func missingResourceAccessorRejectsBeforeWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try SwiftPMResourceAccessor.overlay(for: [product()], in: root, output: root.appendingPathComponent("owned"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func prebuiltMacOSSwiftPMResourcesRejectBeforeBuilding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var app = try product()
        app.source = .prebuilt(path: "App")
        let plan = try Plan(target: app.target, app: app)
        let settings = try await BuildSettings(configuration: .release, triple: app.target.triple, buildSystem: .swiftPM,
                                               packagePath: root.path)
        await #expect(throws: (any Error).self) {
            try await withDependencies {
                $0.productBuildRunner = ProductBuildRunner(build: { _, _ in Issue.record("Unexpected build") },
                                                           binaryPath: { _, _ in Issue.record("Unexpected query"); return "" })
            } operation: {
                try await ProductBuilder(buildSettings: settings, plan: plan).build()
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
