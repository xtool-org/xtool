# Experimental watchOS builds

Build a single-target SwiftUI Watch app with Swift Package Manager. This is an
experimental extension. A separate `dev sign-watch` command provisions and signs
a standalone device bundle. Physical `dev run`, integrated IPA packaging, and
generated Xcode projects are not implemented.
An unsigned `.app` is not installable on a physical Watch by itself.

## Create and build

```sh
xtool new MyWatchApp --platform watchos --skip-setup
cd MyWatchApp
xtool dev build --triple arm64-apple-watchos
```

The generated package targets watchOS 10. Existing packages can opt in with
`platform: watchos` in `xtool.yml` and `.watchOS(.v10)` in `Package.swift`.
This extension's initial supported range starts at watchOS 9. iOS remains the
default when `platform` is omitted.

The default device triple is `arm64_32-apple-watchos`. An explicit architecture
can be selected with `xtool dev build --triple arm64-apple-watchos`. The Ultra 2
running watchOS 27.0.1 requires arm64 and rejects arm64_32. Check architecture
compatibility on the intended device before distribution.

On Linux/WSL, use Swift 6.4 or later. The SDK must include `WatchOS.platform` and,
for simulator builds, `WatchSimulator.platform`. The SDK epoch is bumped so a
normal installation can rebuild its SDK view; slim installations need reinstalling
from Xcode. Installations without Watch platforms continue to support iOS.

## Simulator

On macOS with Xcode and a booted Apple Watch simulator:

```sh
xtool dev run --simulator
```

The simulator must be a Watch destination. As with the existing iOS command,
this installs the bundle; it does not automatically launch it. Simulator execution
requires macOS even when compiling simulator binaries on Linux.

## Current validation and limits

On Ubuntu WSL with Swift 6.4.1 and the watchOS 27 SDK, the modified CLI rebuilt
and installed an isolated SDK, generated a new Watch project, and built `.app`
bundles for `arm64_32`, `arm64`, and the `x86_64` Watch simulator. Binary headers
and bundle metadata were verified. The existing iOS project workflow also built
successfully. All 20 Swift tests passed. Simulator execution has not been tested.
A small arm64 Watch Probe was provisioned using a free Apple Account and installed
on an Ultra 2 running watchOS 27.0.1 from Windows through its paired USB iPhone.
The prototype deployment helper uses companion proxy port forwarding and
`com.apple.streaming_zip_conduit`; Watch AFC upload is unavailable. The Watch
must trust the computer and have Developer Mode enabled and confirmed after restart.
Installation was verified through the Watch's app registry. The owner confirmed
the app launches and responds. The probe's initial example.com request timed out;
the updated probe successfully fetched Apple's HTTPS test page with HTTP 200,
confirmed by the owner on the physical Watch.

Physical Watch deployment still needs integration into xtool and broader hardware
testing. `dev run`
for a physical Watch, `build --sign`, and `build --ipa` fail explicitly rather
than sending a Watch bundle through the iPhone deployment path.

For explicit signing, create a private JSON file with the target Watch's `udid`
and `name`, log in using `xtool auth`, then run:

```sh
xtool dev sign-watch xtool/MyWatchApp.app --device-info watch-device.json
```

The command refuses automatic certificate revocation. Free-account profiles expire
after seven days and need renewal. Do not publish device identifiers, pairing
records, credentials, or private signing keys with a project.

## Physical Watch probe

The repository includes an interactive `Examples/WatchProbe` app and a separate
Python helper under `tools/watchos`. The helper README at `tools/watchos/README.md`
documents Python setup, separate Watch trust, exporting private device info,
revealing the Developer Mode switch when missing, and streaming a signed `.app`
or `.ipa` through a USB iPhone. This helper is experimental and is not part of the
Swift CLI installation. It requires pymobiledevice3 11.31.0 and exactly one paired
Watch in the phone's registry.

From the repository root in WSL, after installing the SDK and preparing the
device as described in the helper README:

```sh
cd Examples/WatchProbe
# Set a unique bundleID in xtool.yml before provisioning.
xtool dev build --triple arm64-apple-watchos
xtool auth
xtool dev sign-watch xtool/WatchProbe.app --device-info ../../.watchos/device.json
```

Return to the repository root in Windows PowerShell and stream that signed bundle:

```powershell
.watchos/venv/Scripts/python.exe tools/watchos/watch_device.py --install Examples/WatchProbe/xtool/WatchProbe.app
```

Open Watch Probe on the Watch to check its counter/haptic screen, session timer,
and foreground HTTPS request. The helper verifies registration, not launch.
The SDK and login must be available to the WSL process used for signing, and the
private `.watchos/device.json` must be visible on the shared Windows filesystem.

The initial sample uses no asset catalogs, third-party frameworks, or extensions.
Those require additional integration testing. Existing legacy SourceKit config
files are preserved; remove `.sourcekit-lsp/config.json` to regenerate one after
changing an existing project's platform. BSP reads the current project platform.
