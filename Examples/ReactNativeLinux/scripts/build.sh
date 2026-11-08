#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source scripts/env.sh
python3 scripts/toolchain.py
if [[ "$(bundle exec pod --version)" != "1.17.0" ]]; then
  echo 'This example requires CocoaPods 1.17.0; see README.md.' >&2
  exit 1
fi
mkdir -p evidence
(cd ios && bundle exec pod install --deployment) > evidence/pod-install.log 2>&1
python3 scripts/patch-dependencies.py
node scripts/bundle.js > evidence/metro-bundle.log 2>&1
python3 scripts/build-native.py 2>&1 | tee evidence/native-build.log
