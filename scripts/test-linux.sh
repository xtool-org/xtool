#!/bin/bash

export APPIMAGE_EXTRACT_AND_RUN=1

cd "$(dirname "$0")"/..

ls -la ./appimage
cp ./appimage/xtool-$(uname -m).AppImage /usr/local/bin/xtool

swift sdk install ./artifacts/sdk/darwin.artifactbundle

mkdir /work
cd /work

xtool sdk install /Xcode.app

xtool new Hello --skip-setup
cd Hello

xtool dev build --ipa
