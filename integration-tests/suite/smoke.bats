setup() {
    bats_require_minimum_version 1.5.0
    bats_load_library bats-support
    bats_load_library bats-assert
}

@test "can run xtool" {
    xtool --version
}

@test "build and run reject nonpositive job counts before setup" {
    for command in build run; do
        for jobs in 0 -1; do
            run xtool dev "$command" --jobs="$jobs"
            assert_failure
            assert_output --partial "--jobs must be greater than zero"
        done
    done
}

@test "can build a fresh app" {
    xtool new --skip-setup MyApp
    cd MyApp
    xtool dev build
    llvm-objdump -p ./xtool/MyApp.app/MyApp | grep "\bcmd LC_BUILD_VERSION\b" -a2 | grep "\bplatform ios\b"
}

@test "build forwards the job limit to SwiftPM" {
    xtool new --skip-setup LimitedApp
    cd LimitedApp
    export XTL_TEST_SWIFT="$(command -v swift)"
    if [[ "$(uname -s)" == Darwin ]]; then
        # The /usr/bin/swift trampoline injects a macOS SDKROOT after xtool
        # removes it, overriding the iOS SDK selected for the build.
        export XTL_TEST_SWIFT="$(xcrun -f swift)"
    fi
    export XTL_TEST_BUILD_ARGUMENTS="$BATS_TEST_TMPDIR/build-arguments"
    mkdir "$BATS_TEST_TMPDIR/bin"
    for tool in build package; do
        cat > "$BATS_TEST_TMPDIR/bin/swift-$tool" <<'SH'
#!/bin/bash
set -euo pipefail
tool="${0##*/swift-}"
if [[ "$tool" == build ]]; then
    printf '%s\n' "$@" > "$XTL_TEST_BUILD_ARGUMENTS"
fi
unset SWIFTPM_CUSTOM_BIN_DIR
exec "$XTL_TEST_SWIFT" "$tool" "$@"
SH
        chmod +x "$BATS_TEST_TMPDIR/bin/swift-$tool"
    done
    export SWIFTPM_CUSTOM_BIN_DIR="$BATS_TEST_TMPDIR/bin"
    xtool dev build --jobs 2
    awk '$0 == "--jobs" { getline; if ($0 == "2") found = 1 } END { exit !found }' "$XTL_TEST_BUILD_ARGUMENTS"
    test -f xtool/LimitedApp.app/LimitedApp
}

@test "slim sdk cannot be updated" {
    run ! xtool sdk update
    assert_output --partial "cannot be updated in place"
}
