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

rm -rf staging
mkdir staging

swift build --package-path .. -c release --product SupersignCLI --static-swift-stdlib
bin="$(swift build --package-path .. -c release --show-bin-path)"
strip "${bin}/SupersignCLI"

curl "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-$(arch).AppImage" \
    -Lo staging/linuxdeploy.AppImage
chmod +x staging/linuxdeploy.AppImage

mkdir -p staging/AppDir/usr/bin
find "${bin}"/ -name '*.resources' -print0 | xargs -0 -I {} cp -a {} "${PWD}/staging/AppDir/usr/bin/"

OUTPUT="staging/Supersign.AppImage" ./staging/linuxdeploy.AppImage \
    --appdir staging/AppDir \
    --output appimage \
    -e "${bin}/SupersignCLI" \
    -d Supersign.desktop \
    -i Supersign.png
mkdir -p packages
mv -f staging/Supersign.AppImage packages/Supersign.AppImage

rm -rf staging

echo "[info] Success!"
