import Foundation
import Testing
@testable import PackLib

@Test func packerCopiesRootResolvedPackagesStore() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("xtool-packer-root-\(UUID().uuidString)", isDirectory: true)
    let packageDir = root.appendingPathComponent("xtool/.xtool-tmp", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
    let resolvedData = Data("{ \"version\" : 3 }\n".utf8)
    try resolvedData.write(to: root.appendingPathComponent("Package.resolved"))

    try Packer.copyResolvedPackagesStore(from: root, to: packageDir)

    #expect(try Data(contentsOf: packageDir.appendingPathComponent("Package.resolved")) == resolvedData)
}


@Test func packerCopiesResolvedPackagesStoreBehindSymbolicLink() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("xtool-packer-root-\(UUID().uuidString)", isDirectory: true)
    let packageDir = root.appendingPathComponent("xtool/.xtool-tmp", isDirectory: true)
    let resolvedTarget = root.appendingPathComponent("resolved-packages")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
    let resolvedData = Data("{ \"version\" : 3 }\n".utf8)
    try resolvedData.write(to: resolvedTarget)
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("Package.resolved"),
        withDestinationURL: resolvedTarget
    )

    try Packer.copyResolvedPackagesStore(from: root, to: packageDir)

    let copiedFile = packageDir.appendingPathComponent("Package.resolved")
    #expect(try Data(contentsOf: copiedFile) == resolvedData)
    #expect(try copiedFile.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
}

@Test func cfBundleSupportedPlatformsFollowsBuildTriple() {
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios") == ["iPhoneOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios-simulator") == ["iPhoneSimulator"])

    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0") == ["iPhoneOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0-simulator") == ["iPhoneSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-ios-simulator") == ["iPhoneSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-macosx") == ["MacOSX"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-macosx") == ["MacOSX"])

    #expect(Packer.cfBundleSupportedPlatforms(for: "unknown-triple") == ["iPhoneOS"])
}
