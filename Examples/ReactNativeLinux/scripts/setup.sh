#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source scripts/env.sh
python3 scripts/toolchain.py
npm ci --ignore-scripts --no-audit --no-fund
gem install --no-document --install-dir "$GEM_HOME" bundler --version 2.6.9
bundle config set --local path .cache/bundle
bundle config set --local frozen true
bundle install
