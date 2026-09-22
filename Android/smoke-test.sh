#!/usr/bin/env bash

# Build xtool and smoke-test it on an Android Virtual Device.

set -euo pipefail

if [[ $# != 1 || ${1:-} == --help || ${1:-} == -h ]]; then
	echo "Usage: $0 <avd-name>" >&2
	exit 2
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."

sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
if [[ -z $sdk ]]; then
	case $(uname -s) in
		Darwin) sdk=$HOME/Library/Android/sdk ;;
		*) sdk=$HOME/Android/Sdk ;;
	esac
fi
adb=$sdk/platform-tools/adb
emulator=$sdk/emulator/emulator
for tool in "$adb" "$emulator"; do
	[[ -x $tool ]] || { echo "Missing $tool; set ANDROID_HOME to your Android SDK." >&2; exit 1; }
done

avd=$1
port=${ANDROID_EMULATOR_PORT:-5580}
boot_timeout=${ANDROID_BOOT_TIMEOUT:-180}
[[ $port =~ ^[0-9]+$ && $boot_timeout =~ ^[0-9]+$ ]] \
	|| { echo "Port and timeout must be integers." >&2; exit 2; }
(( port >= 5554 && port <= 5682 && port % 2 == 0 && boot_timeout > 0 )) \
	|| { echo "Use an even emulator port from 5554 to 5682 and a positive timeout." >&2; exit 2; }
serial=emulator-$port
avds=$("$emulator" -list-avds)
if ! printf '%s\n' "$avds" | grep -Fx -- "$avd" >/dev/null; then
	printf 'Unknown AVD: %s\nAvailable AVDs:\n%s\n' "$avd" "$avds" >&2
	exit 1
fi
"$adb" start-server
devices=$("$adb" devices)
if printf '%s\n' "$devices" | grep -E "^$serial[[:space:]]" >/dev/null; then
	echo "$serial is already in use; set ANDROID_EMULATOR_PORT to another port." >&2
	exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/xtool-android-smoke.XXXXXX")
emulator_pid=
cleanup() {
	local status=$?
	trap - EXIT
	if [[ -n $emulator_pid ]] && kill -0 "$emulator_pid" 2>/dev/null; then
		kill "$emulator_pid" 2>/dev/null || true
		wait "$emulator_pid" 2>/dev/null || true
	fi
	if (( status == 0 )); then
		rm -rf "$work"
	else
		echo "Smoke test failed; logs and staged files: $work" >&2
		tail -n 30 "$work/emulator.log" 2>/dev/null || true
	fi
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "==> Building xtool"
./Android/build.sh --debug 2>&1 | tee "$work/build.log"

echo "==> Booting $avd ($serial)"
"$emulator" -avd "$avd" -port "$port" -read-only -no-snapshot -no-window -no-audio \
	>"$work/emulator.log" 2>&1 &
emulator_pid=$!
deadline=$((SECONDS + boot_timeout))
while [[ $("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') != 1 ]]; do
	kill -0 "$emulator_pid" 2>/dev/null || { echo "Emulator exited before boot." >&2; exit 1; }
	(( SECONDS < deadline )) || { echo "Timed out waiting for Android to boot." >&2; exit 1; }
	sleep 1
done
abi=$("$adb" -s "$serial" shell getprop ro.product.cpu.abi | tr -d '\r')
api=$("$adb" -s "$serial" shell getprop ro.build.version.sdk | tr -d '\r')
[[ $abi == arm64-v8a && $api =~ ^[0-9]+$ ]] && (( api >= 28 )) \
	|| { echo "Expected ARM64 Android API 28+; found $abi API $api." >&2; exit 1; }

echo "==> Running smoke checks on $abi / API $api"

remote=/data/local/tmp/xtool-smoke-${work##*.}
"$adb" -s "$serial" push Android/output "$remote"
"$adb" -s "$serial" shell "$remote/xtool --version" 2>&1 | tee "$work/smoke.log"
