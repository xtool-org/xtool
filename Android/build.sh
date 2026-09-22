#!/usr/bin/env bash

set -euo pipefail

configuration=release
if [[ $# == 1 && $1 == --debug ]]; then
	configuration=debug
elif [[ $# != 0 ]]; then
	echo "Usage: $0 [--debug]" >&2
	exit 2
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ "${XTL_ANDROID_ENV:-}" != 1 ]]; then
	# re-exec inside the Android build environment
	exec docker compose run --build --rm xtool-android env XTL_ANDROID_NESTED=1 Android/build.sh "$@"
fi

source Android/defs.sh

output="$PWD/Android/output"
rm -rf "$output"
mkdir -p "$output"

swift build --product xtool --swift-sdk $ANDROID_ARCH-unknown-linux-android$ANDROID_API_LEVEL -c "$configuration"
cp -a ".build/$ANDROID_ARCH-unknown-linux-android$ANDROID_API_LEVEL/$configuration/xtool" "$output/"

android_libroot="$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/$ANDROID_ARCH-linux-android

# these contain libraries that are already present on device
system_libdirs=(
	"$android_libroot/$ANDROID_API_LEVEL"
)

# these contain libraries that we need to bundle
libdirs=(
	"$android_libroot"
	"$ANDROID_NATIVE_PREFIX"/lib
	"$ANDROID_SWIFT_SDK/swift-android/swift-resources/usr/lib/swift-$ANDROID_ARCH/android"
)

declare -A handled_objs

function copy_deps() {
	for soname in $(readelf -d "$1" | awk '/(NEEDED)/ {print $NF}' | tr -d '[]'); do
		if [[ -v handled_objs[$soname] ]]; then
			continue
		fi

		handled_objs[$soname]=1
		found=0

		for libdir in "${system_libdirs[@]}"; do
			lib="$libdir/$soname"
			[[ -f "$lib" ]] || continue
			found=1
			break
		done

		if [[ $found = 0 ]]; then
			for libdir in "${libdirs[@]}"; do
				lib="$libdir/$soname"
				[[ -f "$lib" ]] || continue
				cp -L "$lib" "$output/"
				copy_deps "$lib"
				found=1
				break
			done
		fi

		if [[ $found = 0 ]]; then
			echo "error: Could not find $soname" >&2
			exit 1
		fi
	done
}

copy_deps "$output/xtool"

if [[ "$configuration" == release ]]; then
	llvm-objcopy --strip-all "$output/xtool"
fi

echo "Built at ./Android/output/xtool"
