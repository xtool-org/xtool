#!/bin/bash

set -euo pipefail
shopt -s nullglob

usage() {
    echo "Usage: $0 [--build | --run] [DemoName]"
}

mode=both
case "${1:-}" in
    --build) mode=build; shift ;;
    --run) mode=run; shift ;;
    -h|--help) usage; exit 0 ;;
esac

if [[ $# -gt 1 || (${1:-} != "" && (${1:-} != Demo* || ${1:-} == */*)) ]]; then
    usage >&2
    exit 1
fi

cd "$(dirname "$0")"
examples_dir="$PWD"
out_dir="$examples_dir/out"

if [[ -n "${1:-}" ]]; then
    demos=("$1")
elif [[ "$mode" == run ]]; then
    demos=()
    for app in "$out_dir"/*.app; do
        name="${app##*/}"
        demos+=("${name%.app}")
    done
else
    demos=()
    for demo in "$examples_dir"/Demo*/; do
        [[ -f "$demo/Package.swift" ]] || continue
        demo="${demo%/}"
        demos+=("${demo##*/}")
    done
fi

if [[ ${#demos[@]} -eq 0 ]]; then
    echo "No demos found. Run $0 --build first if using --run." >&2
    exit 1
fi

logs_dir="$(mktemp -d)"
trap 'rm -rf "$logs_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

build_demo() {
    local demo="$1"
    echo "Building $demo..."
    mkdir -p "$out_dir" || return 1
    # Do not leave an older successful build available after a failed rebuild.
    rm -rf "$out_dir/$demo.app" || return 1
    (cd "$examples_dir/$demo" && xtool dev build --triple arm64-apple-ios-simulator) || return 1
    cp -R "$examples_dir/$demo/xtool/$demo.app" "$out_dir/$demo.app"
}

run_demo() (
    demo="$1"
    app="$out_dir/$demo.app"
    log="$logs_dir/$demo-run.log"
    if [[ ! -d "$app" ]]; then
        echo "Missing $app. Run $0 --build $demo first." >&2
        exit 1
    fi
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist") || exit 1
    echo "Running $demo..."
    xcrun simctl install booted "$app" || exit 1
    xcrun simctl launch --terminate-running-process --console booted "$bundle_id" >"$log" 2>&1 &
    launch_pid=$!
    # A demo should exit shortly after launch. Bound failures that hang instead.
    (
        sleep_pid=""
        trap '[[ -z "$sleep_pid" ]] || kill "$sleep_pid" 2>/dev/null || true' EXIT
        sleep 60 &
        sleep_pid=$!
        wait "$sleep_pid"
        sleep_pid=""
        touch "$log.timeout"
        kill -TERM "$launch_pid" 2>/dev/null || exit 0
        sleep 5 &
        sleep_pid=$!
        wait "$sleep_pid"
        sleep_pid=""
        kill -KILL "$launch_pid" 2>/dev/null || true
    ) >/dev/null 2>&1 &
    timeout_pid=$!
    trap 'kill "$timeout_pid" "$launch_pid" 2>/dev/null || true' EXIT
    status=0
    wait "$launch_pid" || status=$?
    kill "$timeout_pid" 2>/dev/null || true
    wait "$timeout_pid" 2>/dev/null || true
    cat "$log"
    if [[ -f "$log.timeout" ]]; then
        echo "$demo did not terminate within 60 seconds." >&2
        exit 1
    fi
    [[ "$status" -eq 0 ]] && grep -Fxq 'xtool test succeeded' "$log"
)

status=0
for demo in "${demos[@]}"; do
    if [[ "$mode" != run ]] && ! build_demo "$demo"; then
        echo "Build failed: $demo" >&2
        status=1
        continue
    fi
    if [[ "$mode" != build ]] && ! run_demo "$demo"; then
        echo "Test failed: $demo" >&2
        status=1
    fi
done
exit "$status"
