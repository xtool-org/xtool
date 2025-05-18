#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

rm -rf docs

swift package --allow-writing-to-package-directory \
    generate-documentation --target XToolDocs --disable-indexing \
    --output-path docs
