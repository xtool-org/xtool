#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

rm -rf docs

swift package --allow-writing-to-package-directory \
    generate-documentation --target XToolDocs --disable-indexing \
    --experimental-enable-custom-templates \
    --output-path docs
