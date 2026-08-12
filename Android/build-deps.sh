#!/usr/bin/env bash

# Usage: Android/build-deps.sh <install-prefix>
# 
# Cross-compiles necessary native libraries for aarch64 Android.
#
# ANDROID_NDK_HOME must point at an unpacked NDK (>= r27).
# Native clang, clang++, ld.lld, and LLVM archive tools must be on PATH.
#
# After running this, point PKG_CONFIG_PATH and PKG_CONFIG_LIBDIR at
# `<install-prefix>/lib/pkgconfig` so that SwiftPM can find them
# during build.sh.

set -euo pipefail
shopt -s extglob

: "${ANDROID_ARCH:?ANDROID_ARCH must be set}"

TRIPLE=$ANDROID_ARCH-linux-android
PREFIX=${1:?usage: build-deps.sh <install-prefix>}
: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"

rm -rf "$PREFIX"
mkdir -p "$PREFIX"
PREFIX=$(cd "$PREFIX" && pwd)

cd "$(dirname "${BASH_SOURCE[0]}")"
source defs.sh

PROCS=$(nproc)

# Only use the NDK's target headers and libraries, not its host executables.
# The Linux archive labels these directories linux-x86_64 even on ARM hosts.
NDK=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64
RESOURCE_DIR=("$NDK"/lib/clang/*)
export CC="clang --target=$TRIPLE$ANDROID_API_LEVEL --sysroot=$NDK/sysroot -resource-dir=${RESOURCE_DIR[0]}"
export CXX="clang++ --target=$TRIPLE$ANDROID_API_LEVEL --sysroot=$NDK/sysroot -resource-dir=${RESOURCE_DIR[0]}"
export AR=llvm-ar RANLIB=llvm-ranlib NM=llvm-nm
export STRIP="llvm-objcopy --strip-all"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# Point pkg-config exclusively at the cross prefix so the autotools builds
# find each other instead of the host's libraries.
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
# Make all configure probes (not just pkg-config ones) find the prefix
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
	./Configure linux-$ANDROID_ARCH no-tests --prefix="$PREFIX"
	make -j"$PROCS" build_libs
	make install_dev
)

build_autotools() { # <tarball-url> <src-dir> [configure args...]
	local url=$1 dir=$2
	shift 2
	fetch "$url" "$dir.tar"
	tar -C "$WORK" -xf "$WORK/$dir.tar"
	(
		cd "$WORK/$dir"
		./configure --host="$TRIPLE" --prefix="$PREFIX" --enable-shared --disable-static "$@"
		make -j"$PROCS" install
	)
}

# bionic's pthreads are in libc and modern NDKs ship no libpthread;
# provide an empty static lib so -lpthread probes and links resolve.
"$AR" cr "$PREFIX/lib/libpthread.a"

echo "==> curl"
fetch https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz zlib.tar.gz
tar -C "$WORK" -xzf "$WORK/zlib.tar.gz"
(
	cd "$WORK/zlib-1.3.1"
	CHOST="$TRIPLE" CFLAGS="-fPIC" ./configure --prefix="$PREFIX"
	make -j"$PROCS" install
)
build_autotools \
	https://github.com/curl/curl/releases/download/curl-8_16_0/curl-8.16.0.tar.bz2 \
	curl-8.16.0 --enable-shared --disable-static --with-openssl --without-libpsl \
	--without-libidn2 --without-brotli --without-zstd --without-nghttp2 \
	--disable-ldap --disable-ldaps --with-ca-bundle=/system/etc/security/cacerts

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
	./autogen.sh --host="$TRIPLE" --prefix="$PREFIX" --without-cython --enable-shared --disable-static
	make -j"$PROCS" install
)

# unxip links liblzma
echo "==> xz"
fetch https://github.com/tukaani-project/xz/releases/download/v5.6.4/xz-5.6.4.tar.gz xz.tar
tar -C "$WORK" -xf "$WORK/xz.tar"
(
	cd "$WORK/xz-5.6.4"
	./configure --host="$TRIPLE" --prefix="$PREFIX" --enable-shared --disable-static
	make -j"$PROCS" install
)

echo "==> cleaning up $PREFIX"
rm -rf "$PREFIX"/!(include|lib) "$PREFIX"/lib/!(*.so*|pkgconfig)

echo "==> done: native libs installed into $PREFIX"
