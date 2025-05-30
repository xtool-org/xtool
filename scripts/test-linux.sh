#!/bin/bash

export APPIMAGE_EXTRACT_AND_RUN=1

cd "$(dirname "$0")"/..

ls -la ./artifacts

cp ./artifacts/xtool /usr/local/bin/xtool

swift sdk install ./artifacts/darwin.artifactbundle.zip

mkdir /work
cd /work

xtool new Hello --skip-setup
cd Hello

xtool dev build
