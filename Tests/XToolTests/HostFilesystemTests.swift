import Foundation
import Testing
@testable import XToolSupport

@Test func hostFilesystemKindFromTypeNames() {
    #expect(HostFilesystem.kind(fsType: "ext4") == .native)
    #expect(HostFilesystem.kind(fsType: "xfs") == .native)
    #expect(HostFilesystem.kind(fsType: "overlay") == .native)
    #expect(HostFilesystem.kind(fsType: "tmpfs") == .native)
    #expect(HostFilesystem.kind(fsType: "9p") == .network)
    #expect(HostFilesystem.kind(fsType: "drvfs") == .network)
    #expect(HostFilesystem.kind(fsType: "cifs") == .network)
    #expect(HostFilesystem.kind(fsType: "nfs4") == .network)
    #expect(HostFilesystem.kind(fsType: "fuse") == .fuse)
    #expect(HostFilesystem.kind(fsType: "fuse.squashfuse") == .fuse)
    #expect(HostFilesystem.kind(fsType: "fuse.AppImage") == .fuse)
}

@Test func hostFilesystemKindFromStatfsMagic() {
    #expect(HostFilesystem.kind(statfsMagic: 0xEF53) == .native)
    #expect(HostFilesystem.kind(statfsMagic: 0x0102_1997) == .network)
    #expect(HostFilesystem.kind(statfsMagic: 0x6573_5546) == .fuse)
    #expect(HostFilesystem.kind(statfsMagic: 0xFF53_4D42) == .network)
}

@Test func hostFilesystemUnescapesMountFields() {
    #expect(HostFilesystem.unescapeMountField("/mnt/c") == "/mnt/c")
    #expect(HostFilesystem.unescapeMountField("/mnt/c\\040Users") == "/mnt/c Users")
    #expect(HostFilesystem.unescapeMountField("C:\\134Windows") == "C:\\Windows")
}

@Test func hostFilesystemParsesWSLMountInfo() {
    let mountInfo = """
    22 1 8:32 / / rw,relatime - ext4 /dev/sdc rw,discard
    437 22 0:69 / /mnt/c rw,noatime - 9p drvfs rw,dirsync,aname=drvfs;path=C:\\
    500 22 0:80 / /home/user/xip-space\\040dir rw - ext4 /dev/sdd rw
    """
    let mounts = HostFilesystem.parseMountInfo(mountInfo)
    #expect(mounts.contains(HostFilesystem.Mount(mountPoint: "/", fsType: "ext4")))
    #expect(mounts.contains(HostFilesystem.Mount(mountPoint: "/mnt/c", fsType: "9p")))
    #expect(mounts.contains(HostFilesystem.Mount(mountPoint: "/home/user/xip-space dir", fsType: "ext4")))
}

@Test func hostFilesystemPicksLongestMountPrefix() {
    let mounts = [
        HostFilesystem.Mount(mountPoint: "/", fsType: "ext4"),
        HostFilesystem.Mount(mountPoint: "/mnt/c", fsType: "9p"),
        HostFilesystem.Mount(mountPoint: "/mnt", fsType: "ext4"),
    ]
    #expect(HostFilesystem.mount(for: "/home/imohamed/xcode/Xcode.xip", in: mounts)?.fsType == "ext4")
    #expect(HostFilesystem.mount(for: "/mnt/c/Users/me/Xcode.xip", in: mounts)?.fsType == "9p")
    #expect(HostFilesystem.kind(of: "/mnt/c/Users/me/Xcode.xip", mounts: mounts) == .network)
    #expect(HostFilesystem.kind(of: "/home/imohamed/xcode/Xcode.xip", mounts: mounts) == .native)
}

@Test func hostFilesystemStatfsOverridesNativeMountWhenSlow() {
    let mounts = [HostFilesystem.Mount(mountPoint: "/", fsType: "ext4")]
    #expect(
        HostFilesystem.kind(of: "/home/xip", mounts: mounts, statfsMagic: 0x0102_1997) == .network
    )
    #expect(
        HostFilesystem.kind(of: "/home/xip", mounts: mounts, statfsMagic: 0xEF53) == .native
    )
}
