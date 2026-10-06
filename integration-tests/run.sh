#!/bin/bash

set -euo pipefail

xcode_path="${XTL_TEST_XCODE_APP:-}"

if [[ -z "$xcode_path" && $(uname -s) == "Darwin" ]]; then
    xcode_path="$(dirname $(dirname $(/usr/bin/xcode-select -p)))"
fi

if [[ -z "$xcode_path" && -d /usr/local/share/Xcode.app ]]; then
    xcode_path="/usr/local/share/Xcode.app"
fi

if [[ -z "$xcode_path" ]]; then
    echo "Xcode.app not found. Please set XTL_TEST_XCODE_APP."
    exit 1
fi

export XTL_TEST_XCODE_APP="$xcode_path"

if [[ -z "${XTL_TEST_ENV:-}" ]]; then
    [[ -t 1 ]] && tty_flag="-it" || tty_flag=""

    echo "Running"

    exec docker compose run --build --rm -e XTL_CI=1 -v "$xcode_path":/usr/local/share/Xcode.app:ro \
        xtool-test bash -c \
        "./integration-tests/run.sh"
fi

cd "$(dirname "$0")/.."

project_dir="$PWD"

swift build --product xtool
swift test
ln -fs $PWD/.build/debug/xtool /usr/local/bin/xtool
hash -r

mkdir /testroot
cd /testroot
export XDG_CONFIG_HOME="/testroot/config"

echo "Installing SDK"
xtool sdk install --slim "$XTL_TEST_XCODE_APP"

echo "Running tests..."
bats "$project_dir/integration-tests/suite"
