#!/bin/bash

set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <Catalyst SDK root> [swift build options...]" >&2
    exit 1
fi

catalyst_sdk="$1"
shift
catalyst_frameworks="$catalyst_sdk/System/iOSSupport/System/Library/Frameworks"
if [[ "$catalyst_sdk" != /* || ! -d "$catalyst_frameworks" ]]; then
    echo "Expected an absolute MacOSX SDK root containing System/iOSSupport frameworks" >&2
    exit 1
fi

probe_dir="$(mktemp -d)"
trap 'rm -rf "$probe_dir"' EXIT
mkdir -p "$probe_dir/Sources/CatalystSDKConsumer"
cat > "$probe_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CatalystSDKConsumer",
    platforms: [.macCatalyst(.v17)],
    targets: [.target(name: "CatalystSDKConsumer")]
)
SWIFT
cat > "$probe_dir/Sources/CatalystSDKConsumer/View.swift" <<'SWIFT'
import UIKit

@MainActor
public func makeRegistration() -> UICollectionView.CellRegistration<UICollectionViewCell, Int> {
    UICollectionView.CellRegistration { _, _, _ in }
}
SWIFT

swift build --build-system native --package-path "$probe_dir" \
    --swift-sdk darwin --triple arm64-apple-ios-macabi \
    -Xswiftc -F -Xswiftc "$catalyst_frameworks" \
    -Xcc -F -Xcc "$catalyst_frameworks" \
    -Xlinker "-F$catalyst_frameworks" "$@"
