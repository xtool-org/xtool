#!/bin/bash

set -euo pipefail

rm -rf docs

swift package --allow-writing-to-package-directory \
    generate-documentation --target XToolDocs --disable-indexing \
    --output-path docs
