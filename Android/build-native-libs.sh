#!/usr/bin/env bash
# Cross-builds the native libraries xtool links against (OpenSSL and the
# libimobiledevice stack) for aarch64 Android, installing them into a
# separate prefix. Point PKG_CONFIG_PATH and PKG_CONFIG_LIBDIR at its
# lib/pkgconfig directory so that
#   swift build --swift-sdk aarch64-unknown-linux-android28
# can compile and link against them.
#
# Usage: Android/build-native-libs.sh <path-to-swift-android-sdk> <install-prefix>
#   ANDROID_NDK_HOME must point at an unpacked NDK (>= r27).
#   Native clang, clang++, ld.lld, and LLVM archive tools must be on PATH.
#
# The library set mirrors the Linux Docker image (see Dockerfile): OpenSSL
# plus libplist/libimobiledevice-glue/libusbmuxd/libtatsu/libimobiledevice
# from the libimobiledevice project, all built statically. libxadi is not
# needed: XADIProvider is os(Linux)-only (on macOS/Android anisette uses
# Omnisette), so the XADI system library never enters the link.
set -euo pipefail

API=28
TRIPLE=aarch64-linux-android
SDK=${1:?usage: build-native-libs.sh <swift-android-sdk-dir> <install-prefix>}
DEST=${2:?usage: build-native-libs.sh <swift-android-sdk-dir> <install-prefix>}
mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)
: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"

# Only use the NDK's target headers and libraries, not its host executables.
# The Linux archive labels these directories linux-x86_64 even on ARM hosts.
NDK=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64
RESOURCE_DIR=("$NDK"/lib/clang/*)
export CC="clang --target=$TRIPLE$API --sysroot=$NDK/sysroot -resource-dir=${RESOURCE_DIR[0]}"
export CXX="clang++ --target=$TRIPLE$API --sysroot=$NDK/sysroot -resource-dir=${RESOURCE_DIR[0]}"
export AR=llvm-ar RANLIB=llvm-ranlib NM=llvm-nm
export STRIP="llvm-objcopy --strip-all"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PREFIX=$WORK/prefix
mkdir -p "$PREFIX"
# Point pkg-config exclusively at the cross prefix so the autotools builds
# find each other instead of the host's libraries.
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
# Make all configure probes (not just pkg-config ones) find the prefix:
# AC_CHECK_LIB link tests need -L, header checks need -I.
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-fuse-ld=lld -L$PREFIX/lib"

fetch() {
	curl -sfL --retry 3 -o "$WORK/$2" "$1"
}

echo "==> OpenSSL"
fetch \
	https://github.com/openssl/openssl/releases/download/openssl-3.3.2/openssl-3.3.2.tar.gz \
	openssl.tar.gz
tar -C "$WORK" -xzf "$WORK/openssl.tar.gz"
(
	cd "$WORK/openssl-3.3.2"
	./Configure linux-aarch64 no-shared no-tests --prefix="$PREFIX"
	make -j"$(nproc)" build_libs
	make install_dev
)

build_autotools() { # <tarball-url> <src-dir> [configure args...]
	local url=$1 dir=$2
	shift 2
	fetch "$url" "$dir.tar"
	tar -C "$WORK" -xf "$WORK/$dir.tar"
	(
		cd "$WORK/$dir"
		./configure --host="$TRIPLE" --prefix="$PREFIX" "$@"
		make -j"$(nproc)" install
	)
}

# bionic's pthreads are in libc and modern NDKs ship no libpthread;
# provide an empty static lib so -lpthread probes and links resolve.
"$AR" cr "$PREFIX/lib/libpthread.a"

echo "==> libimobiledevice stack"
build_autotools \
	https://github.com/libimobiledevice/libplist/releases/download/2.6.0/libplist-2.6.0.tar.bz2 \
	libplist-2.6.0 --without-cython
build_autotools \
	https://github.com/libimobiledevice/libimobiledevice-glue/releases/download/1.3.1/libimobiledevice-glue-1.3.1.tar.bz2 \
	libimobiledevice-glue-1.3.1
build_autotools \
	https://github.com/libimobiledevice/libusbmuxd/releases/download/2.1.0/libusbmuxd-2.1.0.tar.bz2 \
	libusbmuxd-2.1.0 --without-udev
# libtatsu and libimobiledevice need libcurl (they talk to Apple's TSS
# and activation servers), so build it before them; curl needs zlib,
# which the NDK does not ship pkg-config files for.
echo "==> zlib"
fetch https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz zlib.tar.gz
tar -C "$WORK" -xzf "$WORK/zlib.tar.gz"
(
	cd "$WORK/zlib-1.3.1"
	# position-independent, like everything else we build
	CHOST="$TRIPLE" CFLAGS="-fPIC" ./configure --prefix="$PREFIX" --static
	make -j"$(nproc)" install
)
build_autotools \
	https://github.com/curl/curl/releases/download/curl-8_16_0/curl-8.16.0.tar.bz2 \
	curl-8.16.0 --disable-shared --enable-static --with-openssl --without-libpsl \
	--without-libidn2 --without-brotli --without-zstd --without-nghttp2 \
	--disable-ldap --disable-ldaps --with-ca-bundle=/system/etc/security/cacerts
build_autotools \
	https://github.com/libimobiledevice/libtatsu/releases/download/1.0.4/libtatsu-1.0.4.tar.bz2 \
	libtatsu-1.0.4
# libimobiledevice has no release tarball with the API SwiftyMobileDevice
# needs; use master like the Linux Docker image does.
fetch \
	https://codeload.github.com/libimobiledevice/libimobiledevice/tar.gz/refs/heads/master \
	libimobiledevice.tar.gz
tar -C "$WORK" -xzf "$WORK/libimobiledevice.tar.gz"
(
	cd "$WORK/libimobiledevice-master"
	# git-archive tarballs have no version info; provide one for bootstrap
	git init -q . && git add -A && git -c user.email=ci@localhost -c user.name=ci commit -qm "libimobiledevice master snapshot"
	echo "2.0.1-git" > .tarball-version
	./autogen.sh --host="$TRIPLE" --prefix="$PREFIX" --without-cython
	make -j"$(nproc)" install
)

# unxip links liblzma; build it too.
echo "==> xz"
fetch https://github.com/tukaani-project/xz/releases/download/v5.6.4/xz-5.6.4.tar.gz xz.tar
tar -C "$WORK" -xf "$WORK/xz.tar"
(
	cd "$WORK/xz-5.6.4"
	./configure --host="$TRIPLE" --prefix="$PREFIX" --disable-shared --enable-static
	make -j"$(nproc)" install
)

echo "==> installing into $DEST"
INC_DST=$DEST/include
LIB_DST=$DEST/lib
mkdir -p "$INC_DST" "$LIB_DST"
cp -R "$PREFIX/include/." "$INC_DST/"
cp -a "$PREFIX/lib/"*.a "$LIB_DST/"

# Generate pkg-config files pointing at the installation prefix. SwiftPM's
# systemLibrary targets query pkg-config for cflags/libs; on this host
# pkg-config would otherwise resolve to host libraries.
echo "==> generating pkg-config files"
PC_DST=$DEST/lib/pkgconfig
mkdir -p "$PC_DST"
pc() { # <name> <version> <libs> [requires]
	cat > "$PC_DST/$1.pc" <<EOF
Name: $1
Description: cross-compiled for Android
Version: $2
Libs: -L$LIB_DST $3
Cflags: -I$INC_DST
${4:+Requires: $4}
EOF
}
pc openssl 3.3.2 "-lssl -lcrypto"
pc liblzma 5.6.4 "-llzma"
pc zlib 1.3.1 "-lz"
pc libplist-2.0 2.6.0 "-lplist-2.0"
pc libusbmuxd-2.0 2.1.0 "-lusbmuxd-2.0" "libplist-2.0"
pc libimobiledevice-glue-1.0 1.3.1 "-limobiledevice-glue-1.0" "libplist-2.0"
pc libcurl 8.16.0 "-lcurl -lssl -lcrypto -lz"
# libtatsu's .pc is versioned (libtatsu-1.0) but its libtool target is not:
# it installs libtatsu.a, so the link flag must be -ltatsu.
pc libtatsu-1.0 1.0.4 "-ltatsu -lcurl -lssl -lcrypto -lz" "libplist-2.0"
pc libimobiledevice-1.0 2.0.0 "-limobiledevice-1.0" "libplist-2.0 libusbmuxd-2.0 libimobiledevice-glue-1.0 libtatsu-1.0 libcurl"

# The NDK's prebuilt static libraries (libc.a & co.) carry zstd-compressed
# debug sections, but the swift.org toolchain's lld is built without zstd
# support and errors out reading them ("is compressed with ELFCOMPRESS_ZSTD,
# but lld is not built with zstd support"). Strip debug sections from every
# static archive in the sysroot so lld can consume them. Note -L: the SDK's
# setup-android-sdk.sh symlinks ndk-sysroot/usr/lib/<triple> into the NDK by
# default (SWIFT_ANDROID_NDK_LINK=1), and find's default -P won't traverse it.
# Skip failures: some NDK "archives" (e.g. libc++.a in the per-API dirs) are
# GNU ld scripts, not objects, and llvm-objcopy can't parse them.
find -L "$SDK/ndk-sysroot" -name '*.a' -print0 \
	| xargs -0 -n1 -P1 -I {} bash -c 'llvm-objcopy --strip-debug "$0" 2>/dev/null || true' {}

echo "==> done: native libs installed into $DEST"
