#!/usr/bin/env bash
# Cross-builds the native libraries xtool links against (OpenSSL and the
# libimobiledevice stack) for aarch64 Android, installing them into the
# Swift SDK for Android's NDK sysroot so that
#   swift build --swift-sdk aarch64-unknown-linux-android28
# can compile and link against them.
#
# Usage: Android/build-native-libs.sh <path-to-swift-android-sdk>
#   ANDROID_NDK_HOME must point at an unpacked NDK (>= r27).
#
# The library set mirrors the Linux Docker image (see Dockerfile): OpenSSL
# plus libplist/libimobiledevice-glue/libusbmuxd/libtatsu/libimobiledevice
# from the libimobiledevice project, all built statically. libxadi is not
# needed: XADIProvider is os(Linux)-only (on macOS/Android anisette uses
# Omnisette), so the XADI system library never enters the link.
set -euo pipefail

API=28
TRIPLE=aarch64-linux-android
SDK=${1:?usage: build-native-libs.sh <swift-android-sdk-dir>}
: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"

TOOLCHAIN=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin
export PATH="$TOOLCHAIN:$PATH"
export CC="$TRIPLE$API-clang"
export CXX="$TRIPLE$API-clang++"
export AR=llvm-ar RANLIB=llvm-ranlib STRIP=llvm-strip
export ANDROID_NDK_ROOT=$ANDROID_NDK_HOME

WORK=$(mktemp -d)
PREFIX=$WORK/prefix
mkdir -p "$PREFIX"
# Point pkg-config exclusively at the cross prefix so the autotools builds
# find each other instead of the host's libraries.
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
# Make all configure probes (not just pkg-config ones) find the prefix:
# AC_CHECK_LIB link tests need -L, header checks need -I.
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"

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
	./Configure android-arm64 -D__ANDROID_API__=$API no-shared no-tests \
		--prefix="$PREFIX"
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

echo "==> installing into SDK sysroot"
INC_DST=$SDK/ndk-sysroot/usr/include
LIB_DST=$SDK/ndk-sysroot/usr/lib/$TRIPLE
mkdir -p "$INC_DST" "$LIB_DST"
cp -R "$PREFIX/include/." "$INC_DST/"
cp -a "$PREFIX/lib/"*.a "$LIB_DST/"

# Generate pkg-config files pointing at the sysroot. SwiftPM's
# systemLibrary targets query pkg-config for cflags/libs; on this host
# pkg-config would otherwise resolve to host (x86_64) libraries.
echo "==> generating pkg-config files"
PC_DST=$SDK/swift-android/pkgconfig
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
pc libtatsu-1.0 1.0.4 "-ltatsu-1.0 -lcurl -lssl -lcrypto -lz" "libplist-2.0"
pc libimobiledevice-1.0 2.0.0 "-limobiledevice-1.0" "libplist-2.0 libusbmuxd-2.0 libimobiledevice-glue-1.0 libtatsu-1.0 libcurl"

# SwiftPM links products containing C++ targets (zsign) with -lstdc++ for
# every non-Darwin/FreeBSD/Windows triple (BuildPlan+Product.swift), but
# Android's C++ runtime is libc++ and the NDK ships no libstdc++. Map the
# name onto the NDK's C++ runtime so the link resolves.
echo 'INPUT(-lc++)' > "$LIB_DST/libstdc++.so"

echo "==> done: native libs installed into $SDK"
