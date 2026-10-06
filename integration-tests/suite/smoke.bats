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
