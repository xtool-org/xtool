#!/bin/bash

set -e
shopt -s nullglob

cd "$(dirname "$0")"

# installer version
export VERSION="1.0.0"

if ! command -v fusermount &>/dev/null; then
    # Docker doesn't support FUSE
    export APPIMAGE_EXTRACT_AND_RUN=1
fi

rm -rf staging/tmp
mkdir -p staging/tmp staging/linuxdeploy

swift build --package-path .. -c release --product SupersignCLI --static-swift-stdlib
bin="$(swift build --package-path .. -c release --show-bin-path)"
strip "${bin}/SupersignCLI"

curr_git_info="$(curl -sS https://api.github.com/repos/linuxdeploy/linuxdeploy/git/refs/tags/continuous)"

if [[ -f staging/linuxdeploy/git.json ]]; then
    if ! cmp -s staging/linuxdeploy/git.json <(echo "$curr_git_info"); then
        echo "[info] Updating linuxdeploy"
        rm -rf staging/linuxdeploy/linuxdeploy.AppImage
    fi
else
    echo "[info] Downloading linuxdeploy"
    rm -rf staging/linuxdeploy/linuxdeploy.AppImage
fi

if [[ ! -f staging/linuxdeploy/linuxdeploy.AppImage ]]; then
    curl "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-$(arch).AppImage" \
        -Lo staging/linuxdeploy/linuxdeploy.AppImage
    chmod +x staging/linuxdeploy/linuxdeploy.AppImage
    echo "$curr_git_info" > staging/linuxdeploy/git.json
fi

mkdir -p staging/tmp/AppDir/usr/bin
find "${bin}"/ -name '*.resources' -print0 | xargs -0 -I {} cp -a {} "${PWD}/staging/tmp/AppDir/usr/bin/"

OUTPUT="staging/tmp/Supersign.AppImage" ./staging/linuxdeploy/linuxdeploy.AppImage \
    --appdir staging/tmp/AppDir \
    --output appimage \
    -e "${bin}/SupersignCLI" \
    -d Supersign.desktop \
    -i Supersign.png
mkdir -p packages
mv -f staging/tmp/Supersign.AppImage packages/Supersign.AppImage

rm -rf staging/tmp

echo "[info] Success!"
