setup() {
    bats_require_minimum_version 1.5.0
    bats_load_library bats-support
    bats_load_library bats-assert
}

@test "can run xtool" {
    xtool --version
}

@test "can build a fresh app" {
    xtool new --skip-setup MyApp
    cd MyApp
    xtool dev build
    llvm-objdump -p ./xtool/MyApp.app/MyApp | grep "\bcmd LC_BUILD_VERSION\b" -a2 | grep "\bplatform ios\b"
}

@test "slim sdk cannot be updated" {
    run ! xtool sdk update
    assert_output --partial "cannot be updated in place"
}

@test "can build a fresh watchOS app" {
    [ "${XTL_TEST_WATCHOS:-0}" = 1 ] || skip "Set XTL_TEST_WATCHOS=1 with the Watch SDK installed"
    xtool new --skip-setup --platform watchos MyWatchApp
    cd MyWatchApp
    xtool dev build
    llvm-objdump -p ./xtool/MyWatchApp.app/MyWatchApp | grep "\bcmd LC_BUILD_VERSION\b" -a2 | grep "\bplatform watchos\b"
    run ! xtool dev build --sign
    assert_output --partial "watchOS signing and distribution packaging are not supported yet"
    run ! xtool dev build --ipa
    assert_output --partial "watchOS signing and distribution packaging are not supported yet"
    run ! xtool dev run
    assert_output --partial "Physical Apple Watch deployment is not supported yet"
}
