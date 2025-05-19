#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

rm -rf docs

if type -p xcrun &>/dev/null; then
    docc="$(xcrun -f docc)"
else
    docc="docc"
fi

if [[ $# == 0 ]]; then
    command="convert"
elif [[ $# == 1 && ( "$1" == "preview" || "$1" == "convert" ) ]]; then
    command="$1"
else
    echo "Usage: $0 [convert|preview]"
    exit 1
fi

"$docc" "$command" xtool.docc \
    --experimental-enable-custom-templates \
    --output-path docs
