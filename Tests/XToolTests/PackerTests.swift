import Foundation
import Testing
@testable import PackLib

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

@Test func staticArchivesAreDetectedBareAndInsideUniversalBinaries() throws {
    let archive = Data("!<arch>\n".utf8) + Data(repeating: 0, count: 64)
    let thinArchive = Data("!<thin>\n".utf8) + Data(repeating: 0, count: 64)
    let machO = Data([0xCF, 0xFA, 0xED, 0xFE]) + Data(repeating: 0, count: 64)

    #expect(try isStaticArchive(archive))
    #expect(try isStaticArchive(thinArchive))
    #expect(try isStaticArchive(universalBinary([archive])))
    #expect(try isStaticArchive(universalBinary([archive, thinArchive])))
    #expect(try isStaticArchive(universalBinary([archive, archive], is64: true)))

    #expect(try !isStaticArchive(machO))
    #expect(try !isStaticArchive(universalBinary([machO, machO])))
    #expect(try !isStaticArchive(universalBinary([archive, machO])))
    #expect(try !isStaticArchive(universalBinary([machO, archive], is64: true)))
    #expect(try !isStaticArchive(Data()))
    #expect(try !isStaticArchive(Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2])))
    #expect(try !isStaticArchive(Data([0xCA, 0xFE, 0xBA, 0xBE, 0xFF, 0xFF, 0xFF, 0xFF])))
    #expect(try !isStaticArchive(universalBinary([archive]).prefix(20)))
    #expect(try !isStaticArchive(universalBinary([archive]).prefix(30)))
}

private func universalBinary(_ slices: [Data], is64: Bool = false) -> Data {
    let archSize = is64 ? 32 : 20
    var data = Data()
    data.appendBigEndian(UInt32(is64 ? 0xCAFEBABF : 0xCAFEBABE))
    data.appendBigEndian(UInt32(slices.count))
    var offset = 8 + archSize * slices.count
    for slice in slices {
        data.appendBigEndian(UInt32(0x0100_000C))
        data.appendBigEndian(UInt32(0))
        if is64 {
            data.appendBigEndian(UInt64(offset))
            data.appendBigEndian(UInt64(slice.count))
            data.appendBigEndian(UInt32(3))
            data.appendBigEndian(UInt32(0))
        } else {
            data.appendBigEndian(UInt32(offset))
            data.appendBigEndian(UInt32(slice.count))
            data.appendBigEndian(UInt32(3))
        }
        offset += slice.count
    }
    return slices.reduce(into: data) { $0.append($1) }
}

private func isStaticArchive(_ contents: Data) throws -> Bool {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("xtool-packer-\(UUID().uuidString)")
    try contents.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try Packer.isStaticArchive(at: url)
}

extension Data {
    fileprivate mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
