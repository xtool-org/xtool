import Foundation
import Testing
@testable import PackLib

private let archiveMagic = Data("!<arch>\n".utf8)
private let thinArchiveMagic = Data("!<thin>\n".utf8)
// MH_MAGIC_64 as written on disk by a little-endian arm64 Mach-O
private let machOMagic = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01])

private func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

/// Builds a fat binary whose slices start with the given bytes.
private func fatBinary(slices: [Data], is64: Bool = false) -> Data {
    let entrySize = is64 ? 32 : 20
    var sliceOffset = 8 + slices.count * entrySize
    var header = bigEndian(UInt32(is64 ? 0xCAFEBABF : 0xCAFEBABE)) + bigEndian(UInt32(slices.count))
    var body = Data()
    for slice in slices {
        header += bigEndian(UInt32(0x0100000C)) // CPU_TYPE_ARM64
        header += bigEndian(UInt32(0))
        if is64 {
            header += bigEndian(UInt64(sliceOffset)) + bigEndian(UInt64(slice.count))
            header += bigEndian(UInt32(0)) + bigEndian(UInt32(0)) // align, reserved
        } else {
            header += bigEndian(UInt32(sliceOffset)) + bigEndian(UInt32(slice.count))
            header += bigEndian(UInt32(0)) // align
        }
        body += slice
        sliceOffset += slice.count
    }
    return header + body
}

private func isStaticArchive(_ data: Data) throws -> Bool {
    try Packer.isStaticArchive { offset, count in
        let start = min(Int(offset), data.count)
        return Data(data[start..<min(start + count, data.count)])
    }
}

@Test func staticArchiveDetection() throws {
    #expect(try isStaticArchive(archiveMagic + Data(repeating: 0, count: 64)))
    #expect(try isStaticArchive(thinArchiveMagic + Data(repeating: 0, count: 64)))

    #expect(try isStaticArchive(fatBinary(slices: [archiveMagic])))
    #expect(try isStaticArchive(fatBinary(slices: [archiveMagic, thinArchiveMagic], is64: true)))
    #expect(try !isStaticArchive(fatBinary(slices: [archiveMagic, machOMagic])))
    #expect(try !isStaticArchive(fatBinary(slices: [machOMagic], is64: true)))

    #expect(try !isStaticArchive(machOMagic + Data(repeating: 0, count: 64)))
}

@Test func staticArchiveDetectionRejectsMalformedInput() throws {
    #expect(try !isStaticArchive(Data()))
    #expect(try !isStaticArchive(Data("!<ar".utf8)))
    // fat header claiming one slice but missing its fat_arch entry
    #expect(try !isStaticArchive(bigEndian(UInt32(0xCAFEBABE)) + bigEndian(UInt32(1))))
    // implausible slice count
    #expect(try !isStaticArchive(bigEndian(UInt32(0xCAFEBABE)) + bigEndian(UInt32(10_000))))
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
