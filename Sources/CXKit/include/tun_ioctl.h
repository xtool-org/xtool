#ifndef XTL_TUN_IOCTL_H
#define XTL_TUN_IOCTL_H

// Non-variadic wrappers around the Linux TUN-device ioctls (`ioctl()` itself is a variadic C
// function, which Swift can't call directly). Used by `TUNDevice.swift` to create and configure
// the kernel TUN interface the iOS 17+ RSD tunnel routes traffic through -- see that file's doc
// comment for the wire-level context (CoreDeviceProxy CDTunnel handshake -> this -> RSD lookup).

/// Opens `/dev/net/tun` and creates (or attaches to) a TUN interface (`IFF_TUN | IFF_NO_PI`,
/// i.e. raw IP packets with no per-packet protocol header). The kernel auto-assigns a name
/// (`tunN`); on success it's written into `name_out`, which must have room for at least 16 bytes
/// (`IFNAMSIZ`). Returns the open file descriptor, or -1 on failure (`errno` set).
int xtl_tun_create(char * _Nonnull name_out);

/// Assigns a /`prefix_len` IPv6 address (`addr6`: 16 raw bytes, network byte order) to the named
/// interface, sets its MTU, and brings it up. Returns 0 on success, -1 on failure (`errno` set
/// and `*stage_out` identifies which step failed: 0 = opening the configuration socket,
/// 1 = resolving the interface index, 2 = assigning the address, 3 = setting the MTU,
/// 4 = reading current flags, 5 = writing flags).
///
/// Setting the MTU explicitly matters: a freshly created TUN device defaults to the kernel's
/// standard 1500-byte MTU, which can be larger than the MTU the tunnel peer actually negotiated
/// (e.g. 1280). Leaving the interface at the default risks the kernel handing back a packet
/// larger than a receive buffer sized to the *negotiated* MTU, which it silently truncates to
/// fit -- corrupting the packet stream with no error raised at all.
int xtl_tun_configure(
    const char * _Nonnull name,
    const unsigned char * _Nonnull addr6,
    unsigned int prefix_len,
    unsigned int mtu,
    int * _Nonnull stage_out
);

#endif
