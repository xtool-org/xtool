#!/bin/bash

export APPIMAGE_EXTRACT_AND_RUN=1

cd "$(dirname "$0")"

ls -la ./appimage
./appimage/xtool-aarch64.AppImage --version
