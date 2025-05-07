# Installation (macOS)

Set up xtool for declarative, Xcode-free iOS app development on macOS.

## Overview

This article outlines the steps to install `xtool` for declarative, SwiftPM-driven iOS app development on macOS.

## Prerequisites

### Xcode

Though we don't rely on the Xcode build system, you still need to install Xcode for the iOS SDK and toolchain. You'll want to [install Xcode](https://developer.apple.com/xcode/) and launch it once, completing any installation prompts.

Confirm that Xcode is set up with the iOS SDK:

```bash
xcrun -sdk iphoneos -show-sdk-path
# /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS18.4.sdk
```

As well as Swift:

```bash
swift --version
# swift-driver version: 1.120.5 Apple Swift version 6.1 (swiftlang-6.1.0.110.21 clang-1700.0.13.3)
# Target: arm64-apple-macosx15.0
```

## Installation

### 1. Build xtool

You currently have to build xtool from source on macOS, via Swift Package Manager.

```bash
git clone https://github.com/xtool-org/xtool
# Cloning into 'xtool'...
# Resolving deltas: 100% (1795/1795), done.
cd xtool
swift build -c release --product xtool
# Building for production...
# [503/503] Linking xtool
# Build of product 'xtool' complete! (67.64s)
sudo ln -s "$PWD/.build/release/xtool" /usr/local/bin/xtool
```

> Important:
>
> The SwiftPM build currently references relative libraries and resources. This means you can't just `mv` the built `xtool` binary, hence the usage of `ln` to symlink instead. Make sure you **don't delete the directory where you cloned xtool**.
>
> The plan is to make macOS installation easier and more self-contained in the future by shipping xtool as a `.app`, Homebrew Cask, etc. If you would like to contribute, feel free to reach out via [GitHub Issues](https://github.com/xtool-org/xtool/issues/new).

Confirm that xtool is installed correctly:

```bash
xtool --help
# OVERVIEW: Cross-platform Xcode replacement
# ...
```

### 2. Configure xtool: log in

Perform one-time setup with

```bash
xtool setup
```

You'll be asked to log in:

```
Select login mode
0: API Key (requires paid Apple Developer Program membership)
1: Password (works with any Apple ID but uses private APIs)
Choice (0-1):
```

> Choosing a login mode:
>
> **API Key:** If you have a paid [Apple Developer Program](https://developer.apple.com/programs/enroll/) membership, this is the recommended option. It relies on the public App Store Connect API. You'll want to follow the [instructions](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api) to generate a **Team Key** with the **App Manager** role.
>
> **Password:** If you aren't enrolled in the paid developer program, you'll want to use password-based authentication. This relies on private Apple APIs to authenticate, so you may want to create a throwaway Apple ID to be extra cautious.

Once you select a login mode, you'll be asked to provide the corresponding credentials (API key or email+password+2FA). Needless to say, *your credentials are only sent to Apple* and nobody else (feel free to build xtool from source and check!)

## Next steps

You're now ready to use xtool! See <doc:First-app>. (The tutorial is tailored to Linux, but it works the same on macOS.)
