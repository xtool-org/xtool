#include "tun_ioctl.h"

#if __linux__

#include <fcntl.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <linux/sockios.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

// Deliberately does not include <net/if.h>: it redefines `struct ifreq`/`IFF_*` and conflicts
// with <linux/if.h> if both are pulled in. <sys/socket.h> (needed for `socket()`) doesn't define
// `struct ifreq` itself, so this combination is conflict-free.

int xtl_tun_create(char *name_out) {
    int fd = open("/dev/net/tun", O_RDWR);
    if (fd < 0) return -1;

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_flags = IFF_TUN | IFF_NO_PI;
    if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
        int saved_errno = errno;
        close(fd);
        errno = saved_errno;
        return -1;
    }
    memcpy(name_out, ifr.ifr_name, IFNAMSIZ);
    return fd;
}

// Mirrors the kernel's `struct in6_ifreq` (from <linux/ipv6.h>, which can't be included directly
// alongside <linux/if.h> without further conflicts) -- just the fields actually needed here.
struct xtl_in6_ifreq {
    unsigned char addr[16];
    unsigned int prefixlen;
    int ifindex;
};

int xtl_tun_configure(const char *name, const unsigned char *addr6, unsigned int prefix_len, unsigned int mtu, int *stage_out) {
    int sock = socket(AF_INET6, SOCK_DGRAM, 0);
    if (sock < 0) { *stage_out = 0; return -1; }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    if (ioctl(sock, SIOCGIFINDEX, &ifr) < 0) {
        int saved_errno = errno;
        *stage_out = 1;
        close(sock);
        errno = saved_errno;
        return -1;
    }
    int ifindex = ifr.ifr_ifindex;

    struct xtl_in6_ifreq ifr6;
    memcpy(ifr6.addr, addr6, 16);
    ifr6.prefixlen = prefix_len;
    ifr6.ifindex = ifindex;
    if (ioctl(sock, SIOCSIFADDR, &ifr6) < 0) {
        int saved_errno = errno;
        *stage_out = 2;
        close(sock);
        errno = saved_errno;
        return -1;
    }

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    ifr.ifr_mtu = (int)mtu;
    if (ioctl(sock, SIOCSIFMTU, &ifr) < 0) {
        int saved_errno = errno;
        *stage_out = 3;
        close(sock);
        errno = saved_errno;
        return -1;
    }

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    if (ioctl(sock, SIOCGIFFLAGS, &ifr) < 0) {
        int saved_errno = errno;
        *stage_out = 4;
        close(sock);
        errno = saved_errno;
        return -1;
    }
    ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
    if (ioctl(sock, SIOCSIFFLAGS, &ifr) < 0) {
        int saved_errno = errno;
        *stage_out = 5;
        close(sock);
        errno = saved_errno;
        return -1;
    }

    close(sock);
    return 0;
}

#else

int xtl_tun_create(char *name_out) { (void)name_out; return -1; }
int xtl_tun_configure(const char *name, const unsigned char *addr6, unsigned int prefix_len, unsigned int mtu, int *stage_out) {
    (void)name; (void)addr6; (void)prefix_len; (void)mtu;
    if (stage_out) *stage_out = -1;
    return -1;
}

#endif
