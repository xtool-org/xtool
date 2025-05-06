# xtool

An all-in-one tool/library for sideloading iOS apps and talking to Apple Developer Services. Supports macOS and Linux.

## Prerequisites

- xtool works out of the box on macOS.
- On Linux, you'll need the development packages of [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) + its dependencies.
  - Alternatively, we provide a Dockerfile that does this for you. See [Linux/README.md](/Linux/README.md).

## Installation (CLI)

```bash
$ git clone https://github.com/xtool-org/xtool
$ cd xtool
$ swift run xtool --help
OVERVIEW: The xtool command line interface

USAGE: xtool <subcommand>

OPTIONS:
  -h, --help              Show help information.

SUBCOMMANDS:
  ds                      Interact with Apple Developer Services
  devices                 List devices
  install                 Install an ipa file to your device
  uninstall               Uninstall an installed app
  run                     Run an installed app

  See 'xtool help <subcommand>' for detailed help.
```

## Installation (Library)

Just add `XKit` as a SwiftPM dependency!

```swift
// package dependency:
.package(url: "https://github.com/xtool-org/xtool", .upToNextMinor(from: "1.2.0"))
// target dependency:
.product(name: "XKit", package: "xtool")
```
