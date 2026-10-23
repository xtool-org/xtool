setup() {
    bats_require_minimum_version 1.5.0
    bats_load_library bats-support
    bats_load_library bats-assert
    cd "$BATS_TEST_TMPDIR"
}

@test "can cross-build and verify a relocated macOS app" {
    mkdir -p MacSmoke/Sources/MacSmoke
    cd MacSmoke
    cat > Package.swift <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MacSmoke", platforms: [.macOS(.v15)],
    products: [.executable(name: "MacSmoke", targets: ["MacSmoke"])],
    targets: [.executableTarget(name: "MacSmoke", resources: [.copy("message.txt")])])
SWIFT
    cat > Sources/MacSmoke/main.swift <<'SWIFT'
import Foundation
let file = Bundle.module.url(forResource: "message", withExtension: "txt")!
print(try String(contentsOf: file, encoding: .utf8))
SWIFT
    echo 'macOS resource' > Sources/MacSmoke/message.txt
    architecture="$(uname -m)"
    [[ "$architecture" == aarch64 ]] && architecture=arm64
    cat > xtool.yml <<YAML
version: 2
bundleID: org.xtool.mac-smoke
product: MacSmoke
target: ${architecture}-apple-macosx15.0
source: {kind: executable, product: MacSmoke}
skipLSP: true
YAML

    xtool dev build --configuration release --defer-signing
    test -x xtool/MacSmoke.app/Contents/MacOS/MacSmoke
    test -f xtool/MacSmoke.app/Contents/Info.plist
    test -f xtool/MacSmoke.signing.json
    test -f xtool/MacSmoke.artifact.json
    llvm-objdump -p xtool/MacSmoke.app/Contents/MacOS/MacSmoke |
        grep '\bcmd LC_BUILD_VERSION\b' -a2 | grep '\bplatform macos\b'

    mv xtool ../relocated
    cd ..
    rm -rf MacSmoke
    xtool dev verify relocated/MacSmoke.app
    echo tampered > relocated/MacSmoke.app/Contents/Resources/unexpected.txt
    run xtool dev verify relocated/MacSmoke.app
    assert_failure
    assert_output --partial 'inventory mismatch'
}
