import Foundation
@testable import XKit

/// Builds minimal but signable arm64 apps on any host, and reads back what a signature contains.
enum FakeApp {

    /// A just-valid arm64 `MH_EXECUTE` with room for a code signature
    static func machO() -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func name(_ string: String) {
            data.append(contentsOf: Array(string.utf8) + Array(repeating: 0, count: 16 - string.utf8.count))
        }
        func segment(
            _ segName: String, vmaddr: UInt64, vmsize: UInt64, fileoff: UInt64, filesize: UInt64,
            prot: Int32, sectionCount: UInt32 = 0
        ) {
            append(UInt32(0x19))
            append(UInt32(72 + 80 * sectionCount))
            name(segName)
            append(vmaddr); append(vmsize); append(fileoff); append(filesize)
            append(prot); append(prot); append(sectionCount); append(UInt32(0))
            if sectionCount > 0 {
                name("__text"); name("__TEXT")
                append(UInt64(0x100001000)); append(UInt64(0x100))
                append(UInt32(0x1000)); append(UInt32(2)); append(UInt32(0)); append(UInt32(0))
                append(UInt32(0x80000400)); append(UInt32(0)); append(UInt32(0)); append(UInt32(0))
            }
        }

        var commands = Data()
        swap(&data, &commands)
        segment("__PAGEZERO", vmaddr: 0, vmsize: 0x100000000, fileoff: 0, filesize: 0, prot: 0)
        segment("__TEXT", vmaddr: 0x100000000, vmsize: 0x4000, fileoff: 0, filesize: 0x4000, prot: 5, sectionCount: 1)
        segment("__LINKEDIT", vmaddr: 0x100004000, vmsize: 0x4000, fileoff: 0x4000, filesize: 0x1000, prot: 1)
        for value: UInt32 in [2, 24, 0x4000, 0, 0x4000, 0] { append(value) }
        swap(&data, &commands)

        append(UInt32(0xfeedfacf)); append(Int32(0x0100000c)); append(Int32(0)); append(UInt32(2))
        append(UInt32(4)); append(UInt32(commands.count)); append(UInt32(0x200085)); append(UInt32(0))
        data.append(commands)
        data.append(Data(count: 0x5000 - data.count))
        return data
    }

    @discardableResult
    static func writeBundle(at url: URL, id: String, executable: String = "main") throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": executable]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Info.plist"))
        try machO().write(to: url.appendingPathComponent(executable))
        return url
    }

    /// The entitlements plist stored in the executable's embedded signature, parsed by hand from the
    /// SuperBlob (slot 5) rather than through the signer, so the check doesn't trust the code under test.
    static func entitlements(ofExecutable url: URL) throws -> [String: Any]? {
        let data = try Data(contentsOf: url)
        func u32(_ offset: Int, bigEndian: Bool = false) -> Int {
            let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * UInt32($1)) }
            return Int(bigEndian ? value.byteSwapped : value)
        }
        // walk the load commands to LC_CODE_SIGNATURE (0x1d)
        var offset = 32
        for _ in 0..<u32(16) {
            let cmd = u32(offset), size = u32(offset + 4)
            if cmd == 0x1d {
                let base = u32(offset + 8)
                guard u32(base, bigEndian: true) == 0xfade0cc0 else { return nil }
                for index in 0..<u32(base + 8, bigEndian: true) {
                    let entry = base + 12 + index * 8
                    guard u32(entry, bigEndian: true) == 5 else { continue }
                    let blob = base + u32(entry + 4, bigEndian: true)
                    let length = u32(blob + 4, bigEndian: true)
                    let plist = data.subdata(in: (blob + 8)..<(blob + length))
                    return try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
                }
                return nil
            }
            offset += size
        }
        return nil
    }
}
