# Installation (Linux)

Set up Supersign for iOS app development on Linux.

## Overview

This article outlines the steps to install `supersign` and begin developing iOS apps on Linux.

## Steps

### 1. Install Swift

First, install the latest Swift toolchain for your Linux distribution from <https://swift.org/install/linux>.


After following the steps there, confirm that Swift is installed correctly:

```bash
swift --version
# should say something like:
# Swift version 6.1 (swift-6.1-RELEASE)
```

### 2. Install libimobiledevice

Supersign relies on [libimobiledevice](https://libimobiledevice.org), or more specifically its [usbmuxd](https://github.com/libimobiledevice/usbmuxd) subproject, to talk to your iOS device from Linux.

Your Linux distro probably comes with a `usbmuxd` package, and it may be pre-installed. To check if it is, run:

```bash
file /var/run/usbmuxd
# /var/run/usbmuxd: socket
```

If you instead get a "No such file or directory" error, you need to install `usbmuxd` yourself. On Ubuntu, for example, you can do this with

```bash
sudo apt-get install \
  usbmuxd libimobiledevice6 libimobiledevice-utils 
```

`libimobiledevice6` and `libimobiledevice-utils` aren't strictly needed but they provide tools like `ideviceinfo` that may be useful for interacting with other aspects of your iOS device.

### 3. Download Xcode.xip

From <http://developer.apple.com/download/all/?q=Xcode>, download **Xcode 16.3**. Note the path where `Xcode_16.3.xip` is saved.

### 4. Download Supersign

Next, download the [latest GitHub Release](https://github.com/SuperchargeApp/Supersign/releases/latest) of `Supersign.AppImage` for your architecture. Rename it to `supersign` and add it to a location in your `PATH`.

```bash
curl -fL \
  "https://github.com/SuperchargeApp/Supersign/releases/latest/download/Supersign-$(uname -m).AppImage" \
  -o supersign
chmod +x supersign
sudo mv supersign /usr/local/bin/
```

Confirm that Supersign is installed correctly:

```bash
supersign --help
# OVERVIEW: The Supersign command line tool
# ...
```

### 5. Configure Supersign

Perform one-time setup with

```bash
supersign dev setup
```

You'll first be asked to log in:

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

Once you select a login mode, you'll be asked to provide the corresponding credentials (API key or email+password+2FA). Needless to say, *your credentials are only sent to Apple* and nobody else (feel free to build Supersign from source and check!)

After you're logged in, you'll be asked to provide the path to the `Xcode.xip` file you downloaded earlier.

```
Path to Xcode.xip:
```

Enter the path (for example `~/Downloads/Xcode_16.3.xip`) and hit enter. Supersign will extract the Xcode XIP to generate and install an iOS Swift SDK for you.

Confirm that it worked:

```bash
swift sdk list
# darwin
```

## Next Steps

You're now ready to use Supersign! See <doc:First-app>.
