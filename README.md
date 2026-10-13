# xtool

Cross-platform Xcode replacement. Build and deploy iOS apps with SwiftPM on Linux, Windows, and macOS.

## Overview

xtool is a cross-platform (Linux/WSL/macOS) tool that replicates Xcode functionality with open standards.

✅ Build a SwiftPM package into an iOS app

✅ Sign and install iOS apps

✅ Interact with Apple Developer Services programmatically

## Getting Started

1. Follow the guide to install `xtool`
    - [Installation (Linux/Windows)](https://xtool.sh/documentation/xtooldocs/installation-linux)
    - [Installation (macOS)](https://xtool.sh/documentation/xtooldocs/installation-macos)
2. Create and run your first xtool-powered app by following the [tutorial](https://xtool.sh/tutorials/xtooldocs/first-app)!

## Examples

### Screenshot

![A screenshot of xtool being invoked from VSCode](Documentation/xtool.docc/Resources/Cover.png)

### Command line interface

```bash
$ xtool --help
OVERVIEW: Cross-platform Xcode replacement

USAGE: xtool <subcommand>

OPTIONS:
  -h, --help              Show help information.

CONFIGURATION SUBCOMMANDS:
  setup                   Set up xtool for iOS development
  auth                    Manage Apple Developer Services authentication
  sdk                     Manage the Darwin Swift SDK

DEVELOPMENT SUBCOMMANDS:
  new                     Create a new xtool SwiftPM project
  dev                     Build and run an xtool SwiftPM project
  ds                      Interact with Apple Developer Services

DEVICE SUBCOMMANDS:
  devices                 List devices
  install                 Install an ipa file to your device
  uninstall               Uninstall an installed app
  launch                  Launch an installed app

  See 'xtool help <subcommand>' for detailed help.
```

### macOS development

For a version 2 project targeting `arm64-apple-macosx15.0`:

```sh
xtool dev build --configuration release --defer-signing
xtool dev verify xtool/MyApp.app
# On a Mac, build and run without adding signatures:
xtool dev run --configuration release -- --your-app-argument
# Or run an existing app, including one signed externally:
xtool dev run --app /path/to/MyApp.app -- --your-app-argument
```

The app runs in the foreground with terminal output and exit-status propagation. Ctrl-C
cancels the child process. Apps requiring entitlements or additional signing must be signed
externally first; this workflow does not provision, sign, notarize or install applications.

Copy the `.app`, `.artifact.json`, `.signing.json`, and `.signing-inputs/` together for a
portable handoff. `dev verify` checks the unchanged **pre-signing** bundle, resource files,
executable permissions, internal symlinks and entitlement inputs. Signing changes those bytes;
use `dev run --app` to launch an externally signed app without checking obsolete build hashes.
The inventory also records nested-code signing order and audits static Mach-O dependencies.
It detects changes, but does not authenticate who built the app or prove arbitrary `dlopen` paths.

Linux builds remain Release-only. A prepared SDK can be selected with `--swift-sdks-path`,
and `--scratch-path` selects a separate macOS build directory. macOS project generation,
identity signing and notarization remain separate work.

### Library

xtool includes a library that you can use to interact with Apple Developer Services, iOS devices, and more from your own app. You can use this by adding `XKit` as a SwiftPM dependency.

```swift
// package dependency:
.package(url: "https://github.com/xtool-org/xtool", .upToNextMinor(from: "1.2.0"))
// target dependency:
.product(name: "XKit", package: "xtool")
```
