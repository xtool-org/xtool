#!/usr/bin/env bash
# Source from build.sh; caller supplies the Apple SDK and availability archive.
demo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export CLANG="${CLANG:-$(command -v clang || true)}"
export CLANGXX="${CLANGXX:-$(command -v clang++ || true)}"
export LD64_LLD="${LD64_LLD:-$(command -v ld64.lld || true)}"
export LLVM_AR="${LLVM_AR:-$(command -v llvm-ar || true)}"
export CP_HOME_DIR="${CP_HOME_DIR:-$demo_root/.cache/cocoapods}"
export CP_CACHE_DIR="${CP_CACHE_DIR:-$demo_root/.cache/pods}"
export GEM_HOME="$demo_root/.cache/gems"
export GEM_PATH="$GEM_HOME${GEM_PATH:+:$GEM_PATH}"
export PATH="$demo_root/tools/bin:$GEM_HOME/bin:$PATH"
export RCT_NEW_ARCH_ENABLED=0
export USE_HERMES=0
