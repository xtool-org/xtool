#!/bin/bash

export APPIMAGE_EXTRACT_AND_RUN=1

xtool new Hello --skip-setup
cd Hello

xtool dev build
