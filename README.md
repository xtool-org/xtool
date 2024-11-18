# Supersign

An all-in-one tool/library for sideloading iOS apps and talking to Apple Developer Services. Supports macOS and Linux.

## Prerequisites

- Supersign works out of the box on macOS.
- On Linux, you'll need the development packages of [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) + its dependencies.
  - Alternatively, we provide a Dockerfile that does this for you. See [Linux/README.md](/Linux/README.md).

## Installation (CLI)

```bash
$ git clone https://github.com/SuperchargeApp/Supersign
$ cd Supersign
$ swift run SupersignCLI --help
OVERVIEW: The Supersign command line tool

USAGE: supersign <subcommand>

OPTIONS:
  -h, --help              Show help information.

SUBCOMMANDS:
  ds                      Interact with Apple Developer Services
  devices                 List devices
  install                 Install an ipa file to your device
  uninstall               Uninstall an installed app
  run                     Run an installed app

  See 'supersign help <subcommand>' for detailed help.
```

## Installation (Library)

Just add it as a SwiftPM dependency!

```swift
// package dependency:
.package(url: "https://github.com/SuperchargeApp/Supersign", .upToNextMinor(from: "1.2.0"))
// target dependency:
.product(name: "Supersign", package: "Supersign")
```
