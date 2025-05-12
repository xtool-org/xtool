# Installation (Linux/Windows)

Set up xtool for iOS app development on Linux or Windows.

## Overview

This article outlines the steps to install `xtool` and begin developing iOS apps on Linux (or Windows via WSL).

## Prerequisites

### WSL (for Windows users)

If you're on Windows, you can use xtool via [Windows Subsystem for Linux](https://learn.microsoft.com/en-us/windows/wsl/install) (WSL).

Once you install WSL, you'll also need to set up USB passthrough. See Microsoft's instructions on [installing USBIPD](https://learn.microsoft.com/en-us/windows/wsl/connect-usb). Make sure you're able to bind your iOS device to WSL via USB.

### Swift

Install the Swift 6.1 toolchain for your Linux distribution from <https://swift.org/install/linux>.

After following the steps there, confirm that Swift is installed correctly:

```bash
swift --version
# should say something like:
# Swift version 6.1 (swift-6.1-RELEASE)
```

### usbmuxd

xtool relies on [usbmuxd](https://github.com/libimobiledevice/usbmuxd) to talk to your iOS device from Linux.

Your Linux distro probably offers this package, and it may be preinstalled. To check if it is, run

```bash
usbmuxd --help
# Usage: usbmuxd [OPTIONS]
# ...
```

If instead you get "command not found", you need to install `usbmuxd` yourself. On Ubuntu/Debian, for example, you can do this with

```bash
sudo apt-get install usbmuxd
```

> Other useful tools:
>
> `usbmuxd` is part of the [libimobiledevice](https://libimobiledevice.org) project. You may want to install other libimobiledevice tools, such as `ideviceinfo`, that offer many ways to interact with your iOS device from the command line. On Ubuntu/Debian, you can run
>
> ```bash
> sudo apt-get install libimobiledevice-utils
> # The following NEW packages will be installed:
> #   libimobiledevice-utils
> # 0 upgraded, 1 newly installed
> ideviceinfo
> # DeviceName: Kabir's iPhone
> # SerialNumber: ...
> # UniqueDeviceID: ...
> # ...
> ```

### Xcode.xip

Download **Xcode 16.3** from <https://developer.apple.com/services-account/download?path=/Developer_Tools/Xcode_16.3/Xcode_16.3.xip>. Note the path where `Xcode_16.3.xip` is saved.

> Note:
>
> The URL above requires authentication, so make sure to visit it in your browser rather than running `curl`. You'll be asked to log in with your Apple ID and accept the license agreement to download Xcode.

## Installation

### 1. Download xtool

Once you have the prerequisites, download the [latest GitHub Release](https://github.com/xtool-org/xtool/releases/latest) of `xtool.AppImage` for your architecture. Rename it to `xtool` and add it to a location in your `PATH`.

```bash
curl -fL \
  "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" \
  -o xtool
chmod +x xtool
sudo mv xtool /usr/local/bin/
```

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

### 3. Configure xtool: SDK

After you're logged in, you'll be asked to provide the path to the `Xcode.xip` file you downloaded earlier.

```
Choice (0-1): 0
...
Path to Xcode.xip:
```

Enter the path (for example `~/Downloads/Xcode_16.3.xip`) and hit enter. xtool will extract the Xcode XIP to generate and install an iOS Swift SDK for you.

Confirm that it worked:

```bash
swift sdk list
# darwin
```

## Next steps

You're now ready to use xtool! See <doc:First-app>.
