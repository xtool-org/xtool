import Foundation

/// Classifies the filesystem that backs a path so XIP extraction can avoid
/// WSL 9p/drvfs and FUSE mounts that stall `unxip`.
enum HostFilesystem: Sendable {
    enum Kind: String, Equatable, Sendable {
        case native
        case network
        case fuse

        var isSlow: Bool { self != .native }

        var displayName: String {
            switch self {
            case .native: "native"
            case .network: "network/9p"
            case .fuse: "FUSE"
            }
        }
    }

    struct Mount: Equatable, Sendable {
        var mountPoint: String
        var fsType: String
    }

    static func kind(fsType: String) -> Kind {
        let type = fsType.lowercased()
        switch type {
        case "9p", "drvfs", "cifs", "smb", "smb2", "smb3", "smbfs":
            return .network
        case "nfs", "nfs4", "nfsd":
            return .network
        case "fuse", "fuseblk":
            return .fuse
        default:
            if type.hasPrefix("nfs") { return .network }
            if type.hasPrefix("fuse.") { return .fuse }
            return .native
        }
    }

    static func kind(statfsMagic: Int64) -> Kind {
        switch UInt32(truncatingIfNeeded: statfsMagic) {
        case 0x0102_1997: return .network // V9FS_MAGIC
        case 0x517B, 0xFE53_4D42, 0xFF53_4D42: return .network // SMB / SMB2 / CIFS
        case 0x6969: return .network // NFS_SUPER_MAGIC
        case 0x6573_5546: return .fuse // FUSE_SUPER_MAGIC
        default: return .native
        }
    }

    static func unescapeMountField(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.count)
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == "\\" {
                let digitsStart = raw.index(after: index)
                if let digitsEnd = raw.index(digitsStart, offsetBy: 3, limitedBy: raw.endIndex) {
                    let digits = raw[digitsStart..<digitsEnd]
                    if digits.allSatisfy({ ("0"..."7").contains($0) }), let code = UInt8(digits, radix: 8) {
                        result.append(Character(UnicodeScalar(code)))
                        index = digitsEnd
                        continue
                    }
                }
            }
            result.append(raw[index])
            index = raw.index(after: index)
        }
        return result
    }

    static func parseMountInfo(_ text: String) -> [Mount] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let raw = String(line)
            guard let separator = raw.range(of: " - ") else { return nil }
            let left = raw[raw.startIndex..<separator.lowerBound]
                .split(separator: " ", omittingEmptySubsequences: false)
            let right = raw[separator.upperBound...]
                .split(separator: " ", omittingEmptySubsequences: false)
            guard left.count >= 5, let fsType = right.first else { return nil }
            return Mount(
                mountPoint: unescapeMountField(String(left[4])),
                fsType: String(fsType)
            )
        }
    }

    static func mount(for path: String, in mounts: [Mount]) -> Mount? {
        let standardized = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return mounts
            .filter { mount in
                standardized == mount.mountPoint
                    || standardized.hasPrefix(mount.mountPoint == "/" ? "/" : mount.mountPoint + "/")
            }
            .max(by: { $0.mountPoint.count < $1.mountPoint.count })
    }

    static func kind(
        of path: String,
        mounts: [Mount],
        statfsMagic: Int64? = nil
    ) -> Kind {
        if let statfsMagic {
            let fromStat = kind(statfsMagic: statfsMagic)
            if fromStat.isSlow { return fromStat }
        }
        guard let mount = mount(for: path, in: mounts) else {
            return statfsMagic.map(kind(statfsMagic:)) ?? .native
        }
        return kind(fsType: mount.fsType)
    }

    static func currentMounts() -> [Mount] {
        #if os(Linux)
        let text = (try? String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8)) ?? ""
        return parseMountInfo(text)
        #else
        return []
        #endif
    }

    static func kind(of path: String) -> Kind {
        #if os(Linux)
        kind(of: path, mounts: currentMounts())
        #else
        .native
        #endif
    }

    static func freeBytes(at path: String) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: path) ? path : (path as NSString).deletingLastPathComponent
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: probe),
              let free = attributes[.systemFreeSize] as? NSNumber else {
            return nil
        }
        return free.int64Value
    }
}
