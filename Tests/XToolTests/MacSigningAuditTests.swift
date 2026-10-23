import Foundation
import Testing
@testable import PackLib

struct MacSigningAuditTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("App.app")
        try MacArtifactTests.fixture(at: app)
        return app
    }

    @Test func additionalMacOSExecutableIsAnIndependentSigningNode() throws {
        let app = try fixture()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try MacArtifactTests.binary().write(to: app.appendingPathComponent("Contents/MacOS/Helper"))
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        #expect(try MacBundleAudit.validate(bundle: app, target: target) == ["Contents/MacOS/Helper", ""])
    }

    @Test func differentlyNamedVersionedFrameworkUsesMetadata() throws {
        let app = try fixture()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let framework = app.appendingPathComponent("Contents/Frameworks/Example.framework")
        let version = framework.appendingPathComponent("Versions/A")
        try FileManager.default.createDirectory(at: version.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Actual", "CFBundlePackageType": "FMWK"],
                                           format: .xml, options: 0).write(to: version.appendingPathComponent("Resources/Info.plist"))
        try MacArtifactTests.binary(type: 6).write(to: version.appendingPathComponent("Actual"))
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path,
                                                   withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Actual").path,
                                                   withDestinationPath: "Versions/Current/Actual")
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        #expect(try MacBundleAudit.validate(bundle: app, target: target) == ["Contents/Frameworks/Example.framework", ""])
        #expect(try MacBundleAudit.signingPath(for: "Contents/Frameworks/Example.framework/Actual", in: app)
                == "Contents/Frameworks/Example.framework")
    }

    @Test func multiplePhysicalFrameworkVersionsAreRejected() throws {
        let app = try fixture()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        for version in ["A", "B"] {
            let directory = app.appendingPathComponent("Contents/Frameworks/Example.framework/Versions/" + version)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try MacArtifactTests.binary(type: 6).write(to: directory.appendingPathComponent("Example"))
        }
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        #expect(throws: (any Error).self) { try MacBundleAudit.validate(bundle: app, target: target) }
    }

    @Test func swappedSameNameExecutableIsRejected() throws {
        let app = try fixture()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let nested = app.appendingPathComponent("Contents/XPCServices/Other.xpc")
        try MacArtifactTests.fixture(at: nested)
        let product = try appProduct()
        var manifest = try DeferredSigningManifest(plan: Plan(target: product.target, app: product))
        manifest.products[0].executablePath = "Contents/XPCServices/Other.xpc/Contents/MacOS/App"
        try reject(manifest, app: app)
    }

    @Test func executableAliasIsRejected() throws {
        let app = try fixture()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/MacOS/Alias").path,
                                                   withDestinationPath: "App")
        let product = try appProduct()
        var manifest = try DeferredSigningManifest(plan: Plan(target: product.target, app: product))
        manifest.products[0].executablePath = "Contents/MacOS/Alias"
        try reject(manifest, app: app)
    }

    @Test func incorrectPackageTypeIsRejected() throws {
        let app = try fixture()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let plist = app.appendingPathComponent("Contents/Info.plist")
        var info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        info["CFBundlePackageType"] = "XPC!"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        let product = try appProduct()
        try reject(DeferredSigningManifest(plan: Plan(target: product.target, app: product)), app: app)
    }

    private func appProduct() throws -> Plan.Product {
        Plan.Product(target: try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0"), type: .application,
                     product: "App", bundleID: "test.App", infoPlist: [:], resources: [])
    }

    private func reject(_ manifest: DeferredSigningManifest, app: URL) throws {
        let url = app.deletingPathExtension().appendingPathExtension("signing.json")
        try JSONEncoder().encode(manifest).write(to: url)
        #expect(throws: (any Error).self) { try MacArtifact.write(bundle: app, signingManifest: url) }
    }
}
